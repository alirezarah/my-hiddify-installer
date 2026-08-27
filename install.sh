#!/usr/bin/env bash
# install.sh
# نصب یکپارچه‌ی Hiddify-Manager + رفع خودکار باگ‌های شناخته‌شده.
# استفاده:
#   bash <(curl -Ls https://raw.githubusercontent.com/alirezarah/my-hiddify-installer/refs/heads/main/install.sh)
#
# این اسکریپت:
#   1) نصب رسمی هیدیفای رو اجرا می‌کنه (از اسکریپت رسمی خودشون)
#   2) بلافاصله بعدش، باگ‌های شناخته‌شده رو پچ می‌کنه
#   3) لینک‌های ادمین رو در پایان نشون میده
#
# نکته‌ی مهم: اگه بعداً یه بکاپ از سرور دیگه روی این نصب Restore کردید،
# دوباره همین اسکریپت رو اجرا کنید (یا فقط تابع fix_extra_params رو صدا
# بزنید) چون داده‌ی خراب extra_params معمولاً از طریق بکاپ وارد میشه،
# نه در نصب اولیه.
set -uo pipefail

HIDDIFY_DIR="/opt/hiddify-manager"
NGINX_SERVICE="/etc/systemd/system/hiddify-nginx.service"
PRE_START="$HIDDIFY_DIR/nginx/pre-start.sh"
UTILS_SH="$HIDDIFY_DIR/common/utils.sh"
RUN_COMMANDER=""

if [ "$EUID" -ne 0 ]; then
  echo "این اسکریپت باید با root اجرا بشه."
  exit 1
fi

# =================================================================
# تابع: فیکس extra_params خراب در جدول domain
# قابل فراخوانی جدا بعد از هر Restore بکاپ:
#   bash install.sh --fix-extra-params-only
# =================================================================
fix_extra_params() {
  echo "بررسی extra_params دیتابیس ..."
  if command -v mysql >/dev/null 2>&1 && mysql -u root hiddifypanel -e "SELECT 1" >/dev/null 2>&1; then
    ROWS=$(mysql -u root hiddifypanel -N -B -e "SELECT id, extra_params FROM domain;" 2>/dev/null)
    if [ -n "$ROWS" ]; then
      while IFS=$'\t' read -r id params; do
        [ -z "${id:-}" ] && continue
        echo "$params" | python3 -c "import json,sys; json.loads(sys.stdin.read())" >/dev/null 2>&1 && continue
        echo "  -> دامنه id=$id خراب بود، در حال اصلاح ..."
        fixed=$(python3 -c "
import ast, json, sys
raw = sys.argv[1]
try:
    data = ast.literal_eval(raw)
    print(json.dumps(data))
except Exception:
    print('{}')
" "$params")
        esc=$(printf '%s' "$fixed" | sed "s/'/''/g")
        mysql -u root hiddifypanel -e "UPDATE domain SET extra_params='$esc' WHERE id=$id;" 2>/dev/null
      done <<< "$ROWS"
    fi
    echo "  انجام شد."
  else
    echo "  دیتابیس هنوز آماده نیست یا در دسترس نیست - رد شد."
  fi
}

# اگه فقط برای فیکس بعد از ریستور صدا زده شده، همین رو اجرا کن و خارج شو
if [ "${1:-}" = "--fix-extra-params-only" ]; then
  fix_extra_params
  exit 0
fi

echo "===================================================="
echo " مرحله ۱: نصب رسمی Hiddify-Manager"
echo "===================================================="
bash <(curl -Ls https://raw.githubusercontent.com/hiddify/config/main/install.sh)

echo
echo "===================================================="
echo " مرحله ۲: رفع خودکار باگ‌های شناخته‌شده"
echo "===================================================="

# ---------------------------------------------------------------
# 2.1) فیکس extra_params (روی نصب تازه معمولاً کاری نداره، ولی اگه
#      همزمان با نصب یه بکاپ قدیمی هم ریستور شده باشه بی‌ضرره)
# ---------------------------------------------------------------
echo "[۱/۴] فیکس extra_params ..."
fix_extra_params

# ---------------------------------------------------------------
# 2.2) رفع race condition واقعی نگینکس: کامنت کردن خط touch در
#      خودِ pre-start.sh (نه صرفاً rm کردن pid قبل از استارت،
#      چون در اون صورت pre-start.sh دوباره فایل خالی می‌سازه)
# ---------------------------------------------------------------
echo "[۲/۴] پچ pre-start.sh نگینکس (رفع race condition PID) ..."
if [ -f "$PRE_START" ]; then
  if grep -Eq '^touch[[:space:]]+/run/hiddify-nginx\.pid' "$PRE_START"; then
    cp "$PRE_START" "${PRE_START}.bak.$(date +%s)"
    sed -i -E 's#^touch[[:space:]]+/run/hiddify-nginx\.pid#\#&#' "$PRE_START"
    echo "  خط touch کامنت شد."
  else
    echo "  نیازی نبود (قبلاً پچ شده یا این نسخه باگ رو نداره)."
  fi
else
  echo "  فایل pre-start.sh پیدا نشد - رد شد."
fi

# ---------------------------------------------------------------
# 2.3) افزایش تایم‌اوت چک نهایی سرویس‌ها از ۱۰ به ۳۰ ثانیه در
#      common/utils.sh (رفع "Installation Failed" کاذب هنگام
#      Apply از پنل وب با تعداد زیاد دامنه)
# ---------------------------------------------------------------
echo "[۳/۴] افزایش تایم‌اوت چک سرویس‌ها در utils.sh ..."
if [ -f "$UTILS_SH" ]; then
  if grep -q "seq 1 10" "$UTILS_SH"; then
    cp "$UTILS_SH" "${UTILS_SH}.bak.$(date +%s)"
    sed -i 's/seq 1 10/seq 1 30/' "$UTILS_SH"
    sed -i 's/is not activated after 10 seconds/is not activated after 30 seconds/' "$UTILS_SH"
    echo "  انجام شد (۱۰ -> ۳۰ ثانیه)."
  else
    echo "  نیازی نبود (قبلاً پچ شده یا این نسخه فرق داره)."
  fi
else
  echo "  فایل utils.sh پیدا نشد - رد شد."
fi

# ---------------------------------------------------------------
# 2.4) سخت‌سازی سرویس systemd نگینکس دربرابر start-limit-hit
#      (چون هنگام Apply با چند دامنه، acme.sh چندبار پشت‌سرهم
#      nginx رو ری‌استارت می‌کنه)
# ---------------------------------------------------------------
echo "[۴/۴] اصلاح سرویس systemd هیدیفای-nginx ..."
if [ -f "$NGINX_SERVICE" ]; then
  cp "$NGINX_SERVICE" "${NGINX_SERVICE}.bak.$(date +%s)"
  grep -q "StartLimitIntervalSec=0" "$NGINX_SERVICE" || \
    sed -i "/^Wants=network-online.target/a StartLimitIntervalSec=0" "$NGINX_SERVICE"
  systemctl daemon-reload
  systemctl reset-failed hiddify-nginx 2>/dev/null || true
  systemctl restart hiddify-nginx 2>/dev/null || true
  echo "  انجام شد."
else
  echo "  فایل سرویس پیدا نشد - رد شد."
fi

# ---------------------------------------------------------------
# 2.5) پچ باگ threading در run_commander.py (اختیاری - اگه این
#      نسخه رو نداره بی‌خطر رد میشه)
# ---------------------------------------------------------------
echo "[اضافی] بررسی باگ threading در run_commander.py ..."
RUN_COMMANDER=$(find "$HIDDIFY_DIR" -path "*/hiddifypanel/panel/run_commander.py" 2>/dev/null | head -n1)
if [ -n "$RUN_COMMANDER" ] && [ -f "$RUN_COMMANDER" ]; then
  if grep -q "target=cmd_in_back, daemon=True)" "$RUN_COMMANDER"; then
    cp "$RUN_COMMANDER" "${RUN_COMMANDER}.bak.$(date +%s)"
    sed -i "s/target=cmd_in_back, daemon=True)/target=cmd_in_back, args=(base_cmd,), daemon=True)/" "$RUN_COMMANDER"
    echo "  پچ اعمال شد."
  else
    echo "  نیازی نبود (قبلاً درست بوده یا این نسخه باگ رو نداره)."
  fi
else
  echo "  فایل پیدا نشد - رد شد."
fi

echo
echo "===================================================="
echo " مرحله ۳: ری‌استارت نهایی و بررسی وضعیت"
echo "===================================================="
systemctl restart hiddify-panel hiddify-panel-background-tasks 2>/dev/null || true
sleep 2
systemctl is-active hiddify-panel hiddify-panel-background-tasks hiddify-nginx hiddify-xray hiddify-singbox hiddify-haproxy 2>/dev/null

echo
echo "===================================================="
echo " نصب کامل شد. لینک‌های ادمین:"
echo "===================================================="
echo "" | timeout 15 hiddify admin 2>/dev/null || true
echo
echo "اگه لینک‌های بالا رو ندیدی، دستی این رو بزن:  hiddify admin"
echo
echo "یادآوری: اگه بعداً یه بکاپ از سرور دیگه Restore کردید، دوباره بزنید:"
echo "  bash install.sh --fix-extra-params-only"
