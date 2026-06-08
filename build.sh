#!/usr/bin/env bash
# =============================================================================
#  DAWalka — one-click build & install
# =============================================================================
#
#  Запускайте этот файл из Finder (двойной клик по
#  "Build DAWalka.command") или из терминала:
#
#      ./build.sh
#
#  Скрипт сам:
#    1. проверит и при необходимости установит системные зависимости
#    2. создаст Python venv в ~/Library/Application Support/DAWalka/venv
#    3. поставит MLX (на Apple Silicon), aiohttp, sentencepiece, и т.д.
#    4. скачает модели Stable Audio 3 (Small + Medium) в
#       ~/Library/Application Support/DAWalka/models/
#    5. сконфигурирует и соберёт AUv2 + VST3 плагины
#    6. установит их в ~/Library/Audio/Plug-Ins/Components и VST3
#    7. перерегистрирует Audio Units, проверит auval и VST3 bundle
#
#  Никаких интерактивных вопросов.  Повторный запуск безопасен —
#  уже сделанные шаги пропускаются (инкрементальная сборка).
#
#  Дополнительные флаги:
#
#      ./build.sh --no-install    # только собрать (без установки AU/VST3)
#      ./build.sh --skip-models   # не качать модели (если уже скачаны)
#      ./build.sh --rebuild       # снести build/ и собрать с нуля
#      ./build.sh --verify        # только проверить текущую установку
#      ./build.sh --uninstall     # удалить плагин и его данные
#      ./build.sh --make-app      # после сборки собрать DAWalka.app (UI-инсталлятор)
#      ./build.sh --help          # эта справка
#
#  Для полного удаления используйте отдельный скрипт uninstall.sh
#  (двойной клик по "Uninstall DAWalka.command" в Finder).
#
# =============================================================================
set -uo pipefail
# NOTE: do NOT use `set -e` — many of our sub-commands (downloads,
# auval, etc.) are allowed to fail non-fatally; the `fail` helper is
# what terminates the script on unrecoverable errors.

# ─── Self-locate so the script works from any CWD ──────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
PYTHON_BACKEND="$PROJECT_ROOT/python_backend"
# The venv lives in a STABLE per-machine location (not inside the bundle)
# so the .component stays small (~220 KB) and a single venv is shared
# across all installs/updates.  The plugin's launcher (DAWalka
# Launcher.app) looks here at runtime.
VENV_DIR="$HOME/Library/Application Support/DAWalka/venv"
VENDOR_DIR="$PYTHON_BACKEND/vendor"
BUILD_DIR="$PROJECT_ROOT/build"
USER_AU_DIR="$HOME/Library/Audio/Plug-Ins/Components"
INSTALL_PATH="$USER_AU_DIR/DAWalka.component"
USER_VST3_DIR="$HOME/Library/Audio/Plug-Ins/VST3"
VST3_INSTALL_PATH="$USER_VST3_DIR/DAWalka.vst3"
LOG_DIR="$HOME/Library/Application Support/DAWalka"
MODELS_DIR="$LOG_DIR/models"
# Min free disk required for the full install (models alone are ~6.7 GB,
# plus build artefacts, venv, etc. — be generous).
MIN_FREE_GB=10

# ─── Pretty output ─────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'
else
    BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""
fi

step()  { printf "\n${BLUE}${BOLD}==>${RESET} ${BOLD}%s${RESET}\n" "$1"; }
ok()    { printf "  ${GREEN}✓${RESET} %s\n" "$1"; }
info()  { printf "  ${DIM}%s${RESET}\n" "$1"; }
warn()  { printf "  ${YELLOW}!${RESET} %s\n" "$1"; }
fail()  { printf "\n  ${RED}✗ %s${RESET}\n\n" "$1" >&2; exit 1; }
hr()    { printf "${DIM}%s${RESET}\n" "───────────────────────────────────────────────────────────────"; }

banner() {
    printf "${CYAN}${BOLD}"
    cat <<'EOF'

        ____  ____  __      __    _      _  __      __  _   _
       |  _ \/ _  \ \ \    / /   / \    / \ \ \    / / | \ | |
       | | | | | | | \ \  / /   / _ \  / _ \ \ \  / /  |  \| |
       | |_| | |_| |  \ \/ /   / ___ \/ ___ \ \ \/ /   | |\  |
       |____/ \___/    \__/   /_/   \_\/   \_\ \__/    |_| \_|

              AI Audio Generator · one-click installer

EOF
    printf "${RESET}\n"
}

notify() {
    local title="$1" message="$2"
    if command -v osascript >/dev/null 2>&1; then
        osascript -e "display notification \"$message\" with title \"$title\"" \
                  >/dev/null 2>&1 || true
    fi
}

# Run a command and only print its output on failure (so the success
# path stays quiet, but failures are debuggable).
run_quiet() {
    local log
    log="$(mktemp -t dawalka-build.XXXXXX)"
    if ! "$@" >"$log" 2>&1; then
        printf "\n${RED}─── command failed: $* ───${RESET}\n" >&2
        tail -40 "$log" >&2
        printf "${RED}───────────────────────────${RESET}\n\n" >&2
        rm -f "$log"
        return 1
    fi
    rm -f "$log"
    return 0
}

run_auval_dawalka_check() {
    local timeout="${1:-20}"
    local log pid elapsed rc
    log="$(mktemp -t dawalka-auval.XXXXXX)"

    if ! command -v auval >/dev/null 2>&1; then
        rm -f "$log"
        return 2
    fi

    auval -a >"$log" 2>/dev/null &
    pid=$!
    elapsed=0
    while kill -0 "$pid" 2>/dev/null && [[ $elapsed -lt $timeout ]]; do
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        sleep 1
        kill -9 "$pid" 2>/dev/null || true
        rm -f "$log"
        return 124
    fi

    wait "$pid"
    rc=$?
    if [[ $rc -eq 0 ]] && grep -qi "dawalka" "$log"; then
        rm -f "$log"
        return 0
    fi

    rm -f "$log"
    return 1
}

# Check if a given python interpreter is >= 3.10.  Returns 0 (yes) or
# 1 (no).  Can't use a string compare because "3.9" > "3.10"
# lexicographically.
ver_at_least_310() {
    local py="$1"
    local ver major minor
    ver="$("$py" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)" || return 1
    major="${ver%.*}"
    minor="${ver#*.}"
    (( major > 3 || (major == 3 && minor >= 10) ))
}

# Find a Python >= 3.10 on the system.  macOS's /usr/bin/python3 is
# 3.9 and useless for our venv, so we look at the real install
# locations: Homebrew on Apple Silicon (/opt/homebrew), Homebrew on
# Intel (/usr/local), and python.org's framework
# (/Library/Frameworks/Python.framework).  PATH-based fallback catches
# pyenv, asdf, custom prefixes, etc.  Forward-compatible up to 3.15
# — when multiple 3.10+ versions are present we pick the NEWEST.
find_python_310() {
    local prefixes=(
        /opt/homebrew/bin
        /usr/local/bin
        /Library/Frameworks/Python.framework/Versions
    )
    local versions=(3.15 3.14 3.13 3.12 3.11 3.10)
    local candidates=()
    for prefix in "${prefixes[@]}"; do
        for v in "${versions[@]}"; do
            local p="$prefix/python${v}"
            [[ -x "$p" ]] && candidates+=("$p")
        done
        local p="$prefix/python3"
        [[ -x "$p" ]] && candidates+=("$p")
        # python.org framework: $prefix/3.X/bin/python3
        for d in "$prefix"/3.*/bin/python3; do
            [[ -x "$d" ]] && candidates+=("$d")
        done
    done
    for cmd in python3.15 python3.14 python3.13 python3.12 python3.11 python3.10 python3; do
        if command -v "$cmd" >/dev/null 2>&1; then
            candidates+=("$(command -v "$cmd")")
        fi
    done

    local best="" best_num=0
    for p in "${candidates[@]}"; do
        local ver major minor num
        ver="$("$p" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)" || continue
        major="${ver%.*}"
        minor="${ver#*.}"
        if (( major > 3 || (major == 3 && minor >= 10) )); then
            num=$((major * 1000 + minor))
            if (( num > best_num )); then
                best="$p"
                best_num=$num
            fi
        fi
    done
    [[ -n "$best" ]] && { echo "$best"; return 0; }
    return 1
}

# ─── CLI flags ─────────────────────────────────────────────────────────────
DO_INSTALL=1
DO_UNINSTALL=0
DO_VERIFY=0
DO_DOWNLOAD_MODELS=1
DO_MAKE_APP=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-install)    DO_INSTALL=0; shift;;
        --skip-models)   DO_DOWNLOAD_MODELS=0; shift;;
        --verify)        DO_VERIFY=1; shift;;
        --uninstall)     DO_UNINSTALL=1; shift;;
        --rebuild)       rm -rf "$BUILD_DIR"; shift;;
        --make-app)      DO_MAKE_APP=1; shift;;
        -h|--help)       sed -n '2,38p' "$0"; exit 0;;
        *)               fail "Unknown flag: $1  (try --help)";;
    esac
done

# ─── Verify-only path ──────────────────────────────────────────────────────
if [[ "$DO_VERIFY" -eq 1 ]]; then
    banner
    step "Проверка текущей установки DAWalka"
    errors=0

    if [[ -d "$INSTALL_PATH" ]]; then
        ok "AU plugin: $INSTALL_PATH"
    else
        warn "AU plugin не найден: $INSTALL_PATH"
        errors=$((errors + 1))
    fi

    if [[ -d "$VST3_INSTALL_PATH" ]]; then
        ok "VST3 plugin: $VST3_INSTALL_PATH"
    else
        warn "VST3 plugin не найден: $VST3_INSTALL_PATH"
        errors=$((errors + 1))
    fi

    if [[ -x "$VENV_DIR/bin/python3" ]]; then
        if "$VENV_DIR/bin/python3" -c "import mlx.core, aiohttp, sentencepiece, scipy" 2>/dev/null; then
            ok "venv + все пакеты (mlx, aiohttp, sentencepiece, scipy)"
        else
            warn "venv есть, но не все пакеты установлены. Перезапустите build.sh"
            errors=$((errors + 1))
        fi
    else
        warn "venv не найден: $VENV_DIR"
        errors=$((errors + 1))
    fi

    missing=()
    for f in dit_sm-music_f16.npz dit_sm-sfx_f16.npz dit_medium_f16.npz \
             same_s_decoder_f32.npz same_l_decoder_f32.npz \
             same_s_encoder_f32.npz same_l_encoder_f32.npz \
             t5gemma_f16.npz; do
        if [[ ! -s "$MODELS_DIR/$f" ]]; then
            missing+=("$f")
        fi
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        ok "Все 8 файлов моделей на месте ($(du -sh "$MODELS_DIR" 2>/dev/null | cut -f1))"
    else
        warn "Отсутствуют модели: ${missing[*]}"
        info "  Перезапустите build.sh без --skip-models"
        errors=$((errors + 1))
    fi

    if [[ -d "$VENDOR_DIR/sa3_mlx/models/defs" ]]; then
        ok "vendor/sa3_mlx на месте"
    else
        warn "vendor/sa3_mlx отсутствует"
        errors=$((errors + 1))
    fi

    if command -v auval >/dev/null 2>&1; then
        if auval -a 2>/dev/null | grep -qi "dawalka"; then
            ok "auval находит DAWalka"
        else
            warn "auval НЕ находит DAWalka. Перезапустите Logic"
            errors=$((errors + 1))
        fi
    fi

    echo
    if [[ $errors -eq 0 ]]; then
        printf "  ${GREEN}${BOLD}✓ Всё в порядке${RESET}\n"
        exit 0
    else
        printf "  ${YELLOW}! Найдено проблем: $errors${RESET}\n"
        info "Перезапустите ./build.sh для исправления"
        exit 1
    fi
fi

# ─── Uninstall path (also exposed as uninstall.sh) ─────────────────────────
if [[ "$DO_UNINSTALL" -eq 1 ]]; then
    "$SCRIPT_DIR/uninstall.sh" --yes
    exit $?
fi

# ─── Banner ────────────────────────────────────────────────────────────────
banner
hr
printf "  ${DIM}Проект:${RESET}    %s\n" "$PROJECT_ROOT"
printf "  ${DIM}Сборка:${RESET}    %s\n" "$BUILD_DIR"
printf "  ${DIM}AU:${RESET}        %s\n" "$INSTALL_PATH"
printf "  ${DIM}VST3:${RESET}      %s\n" "$VST3_INSTALL_PATH"
printf "  ${DIM}Python:${RESET}    %s\n" "$VENV_DIR"
hr
echo

# ─── 1. System tools ───────────────────────────────────────────────────────
step "1/8  Проверяю системные инструменты"

ARCH="$(uname -m)"
if [[ "$ARCH" == "arm64" ]]; then
    ok "Apple Silicon ($ARCH)"
elif [[ "$ARCH" == "x86_64" ]]; then
    fail "DAWalka требует Apple Silicon (MLX). Архитектура: $ARCH"
else
    fail "Неизвестная архитектура: $ARCH"
fi

# Disk space check (early — saves a 5 min wasted build if the disk is full)
FREE_GB="$(df -g "$HOME" | awk 'NR==2 {print $4}')"
if [[ -n "$FREE_GB" && "$FREE_GB" -lt "$MIN_FREE_GB" ]]; then
    fail "Мало места: ${FREE_GB} ГБ свободно, нужно минимум ${MIN_FREE_GB} ГБ"
fi
ok "Свободно ${FREE_GB} ГБ (минимум ${MIN_FREE_GB})"

# Xcode Command Line Tools (the macOS C/C++/git toolchain).  Required
# for ANY native build, must be installed BEFORE we can compile.
if ! xcode-select -p >/dev/null 2>&1; then
    warn "Xcode Command Line Tools не установлены"
    info "  macOS откроет диалог установки — нажмите «Установить» и дождитесь"
    info "  После завершения установки запустите build.sh ещё раз"
    xcode-select --install 2>/dev/null || true
    fail "Xcode CLT не установлены. Установите их и запустите build.sh снова"
fi
ok "Xcode CLT: $(xcode-select -p)"

# Homebrew
ensure_brew() {
    if ! command -v brew >/dev/null 2>&1; then
        warn "Homebrew не найден — устанавливаю"
        info "  Установщик попросит пароль администратора (sudo)"
        if ! NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
            fail "Не удалось установить Homebrew. Установите вручную: https://brew.sh"
        fi
        if [[ -f /opt/homebrew/bin/brew ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [[ -f /usr/local/bin/brew ]]; then
            eval "$(/usr/local/bin/brew shellenv)"
        fi
    fi
    ok "Homebrew: $(brew --version | head -1)"
}

# Tool check + auto-install
ensure_tool() {
    local tool="$1" formula="${2:-$1}"
    if ! command -v "$tool" >/dev/null 2>&1; then
        ensure_brew
        warn "$tool не найден — устанавливаю через brew ($formula)"
        if ! brew install "$formula"; then
            fail "Не удалось установить $formula"
        fi
    fi
    ok "$tool: $(command -v "$tool")"
}

ensure_tool git
ensure_tool cmake
# NB: do NOT call ensure_tool for python3 unconditionally — that
# installs python3.10+ from Homebrew even if the user already has a
# newer Python (3.13, 3.14, …) installed at a non-Homebrew location
# (e.g. python.org, pyenv).  We search for an existing 3.10+ first
# and only call ensure_tool as a last resort.  See find_python_310
# below.
if ! PYTHON="$(find_python_310)"; then
    warn "Python 3.10+ не найден — ставлю через Homebrew"
    ensure_tool python3 python
    if ! PYTHON="$(find_python_310)"; then
        fail "Python 3.10+ не найден даже после brew install python"
    fi
fi
export PATH="$(dirname "$PYTHON"):$PATH"
PY_VERSION="$("$PYTHON" -c 'import sys;print("%d.%d"%sys.version_info[:2])')"
ok "Python $PY_VERSION — $PYTHON"

# ─── 2. Python venv ────────────────────────────────────────────────────────
step "2/8  Создаю Python venv в $VENV_DIR"
mkdir -p "$(dirname "$VENV_DIR")"
if [[ ! -d "$VENV_DIR" ]]; then
    if ! "$PYTHON" -m venv "$VENV_DIR"; then
        fail "Не удалось создать venv.  Проверьте, что $PYTHON работает корректно"
    fi
    ok "venv создан"
else
    ok "venv уже существует"
fi

# Use the venv's python interpreter directly.  We deliberately do NOT
# `source $VENV_DIR/bin/activate` because the activate script in older
# venvs (created before the venv was moved out of the .component) has a
# hard-coded VIRTUAL_ENV pointing at the old location, which makes
# PATH point at a non-existent directory and `python` resolve to
# "command not found".  Direct invocation is more robust and avoids
# leaking the activate state into the parent shell.
VENV_PY="$VENV_DIR/bin/python3"
if [[ ! -x "$VENV_PY" ]]; then
    fail "Venv python не найден: $VENV_PY"
fi
VENV_PY_VERSION="$("$VENV_PY" -V 2>&1)"
ok "Активирован $VENV_PY_VERSION — $VENV_PY"

# Keep pip fresh
if ! run_quiet "$VENV_PY" -m pip install --upgrade pip wheel setuptools; then
    fail "Не удалось обновить pip"
fi
ok "pip обновлён"

# ─── 3. Python deps ────────────────────────────────────────────────────────
step "3/8  Ставлю Python зависимости"

# Write a local requirements file if missing
if [[ ! -f "$PYTHON_BACKEND/requirements.txt" ]]; then
    fail "Не найден $PYTHON_BACKEND/requirements.txt"
fi

# Base requirements (no torch/mlx yet — handled below)
if ! run_quiet "$VENV_PY" -m pip install -r "$PYTHON_BACKEND/requirements.txt"; then
    fail "Не удалось поставить базовые пакеты (см. вывод выше)"
fi
ok "Базовые пакеты (aiohttp, numpy, soundfile, scipy, huggingface_hub, …)"

# MLX — Apple Silicon only (REQUIRED for inference)
if [[ "$ARCH" == "arm64" ]]; then
    if ! "$VENV_PY" -c "import mlx.core" 2>/dev/null; then
        warn "Ставлю MLX (Apple Silicon Metal ускорение)…"
        if ! run_quiet "$VENV_PY" -m pip install 'mlx>=0.30'; then
            fail "MLX обязателен на Apple Silicon. pip install mlx не сработал"
        fi
    else
        ok "MLX уже установлен"
    fi
    "$VENV_PY" -c "import mlx.core; print('  MLX', mlx.core.__version__)" 2>/dev/null \
        && ok "MLX доступен" \
        || fail "MLX недоступен после установки"
fi

# SentencePiece (T5Gemma tokenizer)
if ! "$VENV_PY" -c "import sentencepiece" 2>/dev/null; then
    warn "Ставлю sentencepiece (T5Gemma tokenizer)…"
    if ! run_quiet "$VENV_PY" -m pip install 'sentencepiece>=0.2.0'; then
        fail "Не удалось поставить sentencepiece"
    fi
else
    ok "sentencepiece уже установлен"
fi
"$VENV_PY" -c "import sentencepiece; print('  sentencepiece', sentencepiece.__version__)" 2>/dev/null \
    && ok "sentencepiece доступен" \
    || warn "sentencepiece не импортируется — T5Gemma не загрузится"

# ─── 4. Download Stable Audio 3 MLX weights (non-gated) ───────────────────
if [[ "$DO_DOWNLOAD_MODELS" -eq 1 ]]; then
    step "4/8  Скачиваю MLX-веса Stable Audio 3 в $MODELS_DIR"

    mkdir -p "$MODELS_DIR"

    # We use the OFFICIAL pre-converted MLX weights from Stability AI:
    #   stabilityai/stable-audio-3-optimized  (NOT gated)
    # https://github.com/Stability-AI/stable-audio-3/tree/main/optimized/mlx
    #
    # Files are .npz (not safetensors) and need NO PyTorch at runtime.
    # No HF token is required, but a token lifts HF's rate limit.

    # Auth: HF_TOKEN env var, or already-logged-in huggingface-cli (optional)
    if [[ -n "${HF_TOKEN:-}" ]]; then
        "$VENV_PY" -c "from huggingface_hub import login; login(token='${HF_TOKEN}', add_to_git_credential=False)" 2>/dev/null \
            && ok "HuggingFace: авторизация по HF_TOKEN" \
            || warn "HF_TOKEN не принят"
    elif "$VENV_PY" -c "from huggingface_hub import HfApi; HfApi().whoami()" 2>/dev/null; then
        ok "HuggingFace: авторизация по cached credentials"
    else
        info "HuggingFace: анонимные скачивания (для скорости: huggingface-cli login)"
    fi

    # Make sure the .npz files end up in the right place: $MODELS_DIR/<basename>.npz
    # Keep this in sync with Python CATALOGUE and C++ ModelManager::getCatalogue().
    REPO="stabilityai/stable-audio-3-optimized"
    declare -a FILES=(
        "MLX/dit_sm-music_f16.npz"
        "MLX/dit_sm-sfx_f16.npz"
        "MLX/dit_medium_f16.npz"
        "MLX/same_s_decoder_f32.npz"
        "MLX/same_l_decoder_f32.npz"
        "MLX/same_s_encoder_f32.npz"
        "MLX/same_l_encoder_f32.npz"
        "MLX/t5gemma_f16.npz"
    )

    total=${#FILES[@]}
    i=0
    downloaded=0
    skipped=0
    for hf_filename in "${FILES[@]}"; do
        i=$((i+1))
        base=$(basename "$hf_filename")
        out="$MODELS_DIR/$base"
        # NB: must swallow pipefail — `du` returns nonzero when file is missing
        size_mb=$(du -h "$out" 2>/dev/null | cut -f1 || true)
        if [[ -s "$out" ]]; then
            info "  [$i/$total] $base -- уже скачан (${size_mb:-?})"
            skipped=$((skipped+1))
            continue
        fi
        info "  [$i/$total] $base -- скачиваю из $REPO …"
        download_result=$("$VENV_PY" -c "
from huggingface_hub import hf_hub_download
import os, shutil, sys
try:
    p = hf_hub_download(repo_id='$REPO', filename='$hf_filename',
                        local_dir='$MODELS_DIR')
    src = os.path.join('$MODELS_DIR', 'MLX', '$base')
    if os.path.exists(src) and src != '$out':
        os.makedirs('$MODELS_DIR', exist_ok=True)
        if os.path.exists('$out'): os.remove('$out')
        shutil.move(src, '$out')
    try:
        os.rmdir(os.path.join('$MODELS_DIR', 'MLX'))
    except OSError: pass
    print('OK ' + str(os.path.getsize('$out')))
    sys.exit(0)
except Exception as e:
    print('ERR ' + str(e)[:400])
    sys.exit(0)
" 2>&1) || true
        # The python script always exits 0 to avoid set -e triggering.
        # Take the LAST line — the actual result — since stderr warnings
        # from huggingface_hub can appear before the final OK/ERR.
        result_line=$(echo "$download_result" | tail -n 1)
        if [[ "$result_line" == OK* ]]; then
            ok "  [$i/$total] $base"
            downloaded=$((downloaded+1))
        else
            warn "  [$i/$total] $base -- $result_line"
            info "  Если это ошибка сети — перезапустите build.sh, скачивание продолжится"
        fi
    done

    ok "Готово: скачано $downloaded, уже было $skipped. Размер каталога: $(du -sh "$MODELS_DIR" 2>/dev/null | cut -f1 || echo ?)"

    # Clean up any old stable-audio-tools leftovers from a previous build
    if [[ -d "$VENDOR_DIR/stable-audio-tools" ]]; then
        info "Удаляю старый vendor/stable-audio-tools (больше не нужен)"
        rm -rf "$VENDOR_DIR/stable-audio-tools"
    fi
else
    info "Шаг 4 пропущен (--skip-models)"
fi

# ─── 5. Vendored sa3_mlx (pure-MLX inference) ─────────────────────────────
step "5/8  Проверяю vendor/sa3_mlx"
mkdir -p "$VENDOR_DIR"
if [[ ! -d "$VENDOR_DIR/sa3_mlx/models/defs" ]]; then
    warn "vendor/sa3_mlx отсутствует — клонирую Stability-AI/stable-audio-3…"
    rm -rf "$VENDOR_DIR/sa3_mlx"
    rm -rf /tmp/sa3_clone
    if ! git clone --depth 1 --filter=blob:none --sparse https://github.com/Stability-AI/stable-audio-3.git /tmp/sa3_clone 2>&1 | tail -3; then
        fail "Не удалось склонировать stabilityai/stable-audio-3 (проверьте интернет)"
    fi
    (cd /tmp/sa3_clone && git sparse-checkout set optimized/mlx && cp -R optimized/mlx "$VENDOR_DIR/sa3_mlx")
    rm -rf /tmp/sa3_clone
    # Clean up the bits we don't need to keep the bundle small
    rm -rf "$VENDOR_DIR/sa3_mlx/ableton" \
           "$VENDOR_DIR/sa3_mlx/benchmark.sh" \
           "$VENDOR_DIR/sa3_mlx/bootstrap.sh" \
           "$VENDOR_DIR/sa3_mlx/install.sh" \
           "$VENDOR_DIR/sa3_mlx/sa3"
    rm -f "$VENDOR_DIR/sa3_mlx/scripts/install.py" \
          "$VENDOR_DIR/sa3_mlx/scripts/test_all_configs.py" \
          "$VENDOR_DIR/sa3_mlx/scripts/benchmark.py" \
          "$VENDOR_DIR/sa3_mlx/scripts/examples.py"
    if [[ ! -d "$VENDOR_DIR/sa3_mlx/models/defs" ]]; then
        fail "vendor/sa3_mlx развернулся некорректно (нет models/defs)"
    fi
    ok "vendor/sa3_mlx развёрнут (pure MLX, no PyTorch)"
else
    ok "vendor/sa3_mlx уже на месте"
fi

# ─── 6. Build C++ plugin ───────────────────────────────────────────────────
step "6/8  Конфигурирую и собираю AUv2 + VST3 (может занять 5-15 минут в первый раз)"

NCPU="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
info "Потоков сборки: $NCPU"

if [[ -d "$BUILD_DIR" ]]; then
    # CMakeCache.txt хранит абсолютный путь к исходникам той машины, где
    # была сделана первая конфигурация. Если мы сейчас на другой машине
    # (например, проект скопировали на ноутбук) — кэш невалиден и
    # `cmake --build` упадёт с "directory is different than the directory
    # where CMakeCache.txt was created". Автоматически сносим и
    # переконфигурируем.
    CACHE_FILE="$BUILD_DIR/CMakeCache.txt"
    if [[ ! -f "$CACHE_FILE" ]]; then
        warn "build/ без CMakeCache.txt — переконфигурирую"
        rm -rf "$BUILD_DIR"
    else
        CACHED_SRC="$(grep -E '^CMAKE_HOME_DIRECTORY:' "$CACHE_FILE" 2>/dev/null \
                      | head -1 | cut -d= -f2- | sed 's/[[:space:]]*$//')"
        if [[ -n "$CACHED_SRC" && "$CACHED_SRC" != "$PROJECT_ROOT" ]]; then
            warn "build/CMakeCache.txt от другой машины:"
            warn "    было:   $CACHED_SRC"
            warn "    стало:  $PROJECT_ROOT"
            info "Сношу build/ и переконфигурирую"
            rm -rf "$BUILD_DIR"
        fi
    fi
fi

if [[ ! -d "$BUILD_DIR" ]]; then
    if ! cmake -S "$PROJECT_ROOT" -B "$BUILD_DIR" \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0; then
        fail "CMake configure не сработал. Проверьте, что Xcode CLT и cmake установлены"
    fi
    ok "CMake сконфигурирован"
else
    ok "CMake build уже сконфигурирован"
fi

if ! cmake --build "$BUILD_DIR" --config Release --parallel "$NCPU"; then
    fail "Сборка провалилась. Смотрите лог cmake выше"
fi
ok "Сборка завершена"

AU_BUNDLE="$BUILD_DIR/AU/DAWalka.component"
if [[ ! -d "$AU_BUNDLE" ]]; then
    fail "AU бандл не найден: $AU_BUNDLE"
fi
ok "AUv2: $AU_BUNDLE ($(du -sh "$AU_BUNDLE" 2>/dev/null | cut -f1 || echo ?))"

VST3_BUNDLE="$BUILD_DIR/VST3/DAWalka.vst3"
if [[ ! -d "$VST3_BUNDLE" ]]; then
    fail "VST3 бандл не найден: $VST3_BUNDLE"
fi
ok "VST3: $VST3_BUNDLE ($(du -sh "$VST3_BUNDLE" 2>/dev/null | cut -f1 || echo ?))"

# Safety net: if the CMake POST_BUILD step didn't copy python_backend for
# any reason (older build, manual cmake run, etc.), copy it now.
embed_python_backend() {
    local target="$1"
    if [[ -d "$target/Contents/Resources/python_backend" ]]; then
        return 0
    fi
    warn "python_backend не найден в $target — встраиваю сейчас"
    mkdir -p "$target/Contents/Resources"
    cp -R "$PYTHON_BACKEND" "$target/Contents/Resources/python_backend"
}

sign_plugin_bundle() {
    local target="$1"
    if [[ -d "$target" ]] && command -v codesign >/dev/null 2>&1; then
        if codesign --force --deep --sign - "$target" >/dev/null 2>&1; then
            ok "Ad-hoc подпись обновлена: $target"
        else
            warn "Не удалось обновить ad-hoc подпись: $target"
        fi
    fi
}

embed_python_backend "$AU_BUNDLE"
embed_python_backend "$VST3_BUNDLE"
sign_plugin_bundle "$AU_BUNDLE"
sign_plugin_bundle "$VST3_BUNDLE"
ok "python_backend встроен в AU ($(du -sh "$AU_BUNDLE/Contents/Resources/python_backend" 2>/dev/null | cut -f1 || echo ?))"
ok "python_backend встроен в VST3 ($(du -sh "$VST3_BUNDLE/Contents/Resources/python_backend" 2>/dev/null | cut -f1 || echo ?))"

# ─── 7. Install to user Audio Plug-Ins folders ─────────────────────────────
if [[ "$DO_INSTALL" -eq 1 ]]; then
    step "7/8  Устанавливаю AUv2 + VST3"
    mkdir -p "$USER_AU_DIR"
    mkdir -p "$USER_VST3_DIR"
    rm -rf "$INSTALL_PATH"
    rm -rf "$VST3_INSTALL_PATH"
    cp -R "$AU_BUNDLE" "$USER_AU_DIR/"
    cp -R "$VST3_BUNDLE" "$USER_VST3_DIR/"
    # Belt-and-suspenders: re-embed python_backend in the installed copy
    # in case `cp -R` missed it or we want to make absolutely sure.
    embed_python_backend "$INSTALL_PATH"
    embed_python_backend "$VST3_INSTALL_PATH"
    sign_plugin_bundle "$INSTALL_PATH"
    sign_plugin_bundle "$VST3_INSTALL_PATH"
    ok "AU установлено: $INSTALL_PATH"
    ok "VST3 установлено: $VST3_INSTALL_PATH"

    step "8/8  Перерегистрирую Audio Units"
    killall -9 audiounitservicecrasher 2>/dev/null || true

    if command -v auval >/dev/null 2>&1; then
        if run_auval_dawalka_check 20; then
            ok "auval подтвердил регистрацию"
        else
            case $? in
                124)
                    warn "auval завис дольше 20 секунд — пропускаю, чтобы installer не висел"
                    ;;
                *)
                    warn "auval не нашёл DAWalka. Перезапустите Logic или выполните вручную:"
                    warn "    auval -a | grep -i dawalka"
                    ;;
            esac
        fi
    else
        info "auval недоступен — пропускаю проверку"
    fi

    if [[ -d "$VST3_INSTALL_PATH/Contents/Resources/python_backend" ]]; then
        ok "VST3 bundle содержит python_backend"
    else
        warn "VST3 bundle установлен, но python_backend не найден"
    fi
else
    step "7/8  Пропускаю установку (--no-install)"
    step "8/8  Перерегистрирую Audio Units / проверяю VST3 (пропущено)"
    warn "Установите плагины вручную:"
    warn "    cp -R \"$AU_BUNDLE\" \"$USER_AU_DIR/\""
    warn "    cp -R \"$VST3_BUNDLE\" \"$USER_VST3_DIR/\""
fi

# ─── 9. Final verification ─────────────────────────────────────────────────
step "Финальная проверка"
verify_errors=0

# Plugins
if [[ -d "$INSTALL_PATH" && "$DO_INSTALL" -eq 1 ]]; then
    ok "AU plugin: $INSTALL_PATH"
elif [[ "$DO_INSTALL" -eq 0 ]]; then
    ok "AU plugin собран: $AU_BUNDLE"
else
    warn "AU plugin не установлен"
    verify_errors=$((verify_errors + 1))
fi

if [[ -d "$VST3_INSTALL_PATH" && "$DO_INSTALL" -eq 1 ]]; then
    ok "VST3 plugin: $VST3_INSTALL_PATH"
elif [[ "$DO_INSTALL" -eq 0 ]]; then
    ok "VST3 plugin собран: $VST3_BUNDLE"
else
    warn "VST3 plugin не установлен"
    verify_errors=$((verify_errors + 1))
fi

# venv + key packages
if [[ -x "$VENV_DIR/bin/python3" ]]; then
    if "$VENV_DIR/bin/python3" -c "import mlx.core, aiohttp, sentencepiece, scipy, soundfile, huggingface_hub" 2>/dev/null; then
        ok "venv: все пакеты на месте"
    else
        warn "venv: не все пакеты импортируются"
        verify_errors=$((verify_errors + 1))
    fi
fi

# Models
missing_models=()
for f in dit_sm-music_f16.npz dit_sm-sfx_f16.npz dit_medium_f16.npz \
         same_s_decoder_f32.npz same_l_decoder_f32.npz \
         same_s_encoder_f32.npz same_l_encoder_f32.npz \
         t5gemma_f16.npz; do
    [[ ! -s "$MODELS_DIR/$f" ]] && missing_models+=("$f")
done
if [[ ${#missing_models[@]} -eq 0 ]]; then
    ok "Модели: все 8 .npz на месте"
else
    warn "Модели: отсутствуют ${missing_models[*]}"
    verify_errors=$((verify_errors + 1))
fi

# Vendor
[[ -d "$VENDOR_DIR/sa3_mlx/models/defs" ]] \
    && ok "vendor/sa3_mlx на месте" \
    || { warn "vendor/sa3_mlx отсутствует"; verify_errors=$((verify_errors + 1)); }

# auval (only if we installed)
if [[ "$DO_INSTALL" -eq 1 ]] && command -v auval >/dev/null 2>&1; then
    if run_auval_dawalka_check 20; then
        ok "auval: DAWalka зарегистрирован"
    else
        case $? in
            124)
                warn "auval: проверка зависла дольше 20 секунд — пропускаю"
                ;;
            *)
                warn "auval: DAWalka не виден. Перезапустите Logic"
                verify_errors=$((verify_errors + 1))
                ;;
        esac
    fi
fi

# ─── Summary ───────────────────────────────────────────────────────────────
hr
echo
if [[ $verify_errors -eq 0 ]]; then
    printf "  ${GREEN}${BOLD}✓ DAWalka готов к работе!${RESET}\n"
else
    printf "  ${YELLOW}${BOLD}! Сборка завершена с предупреждениями ($verify_errors)${RESET}\n"
    info "Смотрите сообщения выше"
fi
hr
echo
printf "  ${BOLD}AU plugin:${RESET}     %s\n" "$INSTALL_PATH"
printf "  ${BOLD}VST3 plugin:${RESET}   %s\n" "$VST3_INSTALL_PATH"
printf "  ${BOLD}Python venv:${RESET}   %s\n" "$VENV_DIR"
printf "  ${BOLD}Модели:${RESET}        %s (%s)\n" "$MODELS_DIR" "$(du -sh "$MODELS_DIR" 2>/dev/null | cut -f1 || echo ?)"
printf "  ${BOLD}Логи:${RESET}          ~/Library/Application Support/DAWalka/backend.log"
printf "\n\n"
printf "  ${BOLD}Следующие шаги:${RESET}\n"
printf "    1. Откройте ${BOLD}Logic Pro${RESET}, Reaper, Bitwig или другой AU/VST3 host\n"
printf "    2. Создайте дорожку с инструментом/генератором\n"
printf "    3. Выберите ${BOLD}DAWalka${RESET} из AU или VST3 списка\n"
printf "    4. Наберите промпт и нажмите ${BOLD}GENERATE${RESET}\n"
printf "       (модели и зависимости уже установлены — нажмите один раз)\n"
printf "\n"
printf "  ${BOLD}Для проверки установки:${RESET}  ./build.sh --verify\n"
printf "  ${BOLD}Для удаления:${RESET}            ./uninstall.sh\n"
printf "\n"
hr
echo

# ─── 10. Optional: build the UI installer .app ────────────────────────────
# Run with --make-app if you want to ship DAWalka.app to other users
# (e.g. for distribution).  The .app contains the pre-built component
# and a Cocoa UI, so end users can install/uninstall with a double
# click — bypassing the macOS Gatekeeper "bad interpreter" error that
# hits .command files when they're quarantined.
if [[ "$DO_MAKE_APP" -eq 1 ]]; then
    step "Собираю DAWalka.app (UI-инсталлятор)"
    if [[ -x "$PROJECT_ROOT/installer/make_app.sh" ]]; then
        # --rebuild so we always overwrite (the user asked for a fresh
        # build this run anyway)
        if "$PROJECT_ROOT/installer/make_app.sh" --rebuild; then
            ok "DAWalka.app готов: $PROJECT_ROOT/DAWalka.app"
        else
            warn "make_app.sh завершился с ошибкой"
        fi
    else
        warn "installer/make_app.sh не найден — пропускаю"
    fi
fi

[[ $verify_errors -eq 0 ]] && notify "DAWalka" "Сборка и установка завершены успешно ✅" \
                           || notify "DAWalka" "Сборка завершена с предупреждениями"
