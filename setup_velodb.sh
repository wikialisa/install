#!/usr/bin/env bash
set -Eeuo pipefail

DB_HOST='lb-85416965-5de17699210eecee.elb.us-east-1.amazonaws.com'
DB_PORT='9030'
DB_USER='admin'
DB_NAME='wikialisa_sign'
DB_PREFIX='wa_'
ADMIN_NAME='admin'
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DDL_FILE="$SCRIPT_DIR/install_create_velodb.sql"

if [[ ! -r "$DDL_FILE" ]]; then
  printf 'Không tìm thấy file DDL: %s\n' "$DDL_FILE" >&2
  exit 1
fi

if command -v mysql >/dev/null 2>&1; then
  CLIENT_MODE='local'
  MYSQL_CLIENT=(mysql)
elif command -v mariadb >/dev/null 2>&1; then
  CLIENT_MODE='local'
  MYSQL_CLIENT=(mariadb)
elif command -v docker >/dev/null 2>&1; then
  CLIENT_MODE='docker'
else
  printf 'Cần cài mysql/mariadb client hoặc Docker để chạy MySQL client.\n' >&2
  exit 1
fi

read -r -s -p 'Mật khẩu VeloDB (nhập trực tiếp, không hiện ký tự): ' DB_PASSWORD
printf '\n'
if [[ -z "$DB_PASSWORD" ]]; then
  printf 'Mật khẩu không được để trống.\n' >&2
  exit 1
fi

MYSQL_CNF="$(mktemp)"
chmod 600 "$MYSQL_CNF"
cleanup() {
  rm -f -- "$MYSQL_CNF"
}
trap cleanup EXIT

escaped_password=${DB_PASSWORD//\\/\\\\}
escaped_password=${escaped_password//\"/\\\"}
printf '[client]\nhost=%s\nport=%s\nuser=%s\npassword="%s"\nprotocol=tcp\n' \
  "$DB_HOST" "$DB_PORT" "$DB_USER" "$escaped_password" > "$MYSQL_CNF"
unset DB_PASSWORD escaped_password

run_mysql() {
  if [[ "$CLIENT_MODE" == 'docker' ]]; then
    docker run --rm -i --network host \
      -v "$MYSQL_CNF:/tmp/client.cnf:ro" \
      mysql:8.4 mysql --defaults-extra-file=/tmp/client.cnf "$@"
  else
    "${MYSQL_CLIENT[@]}" --defaults-extra-file="$MYSQL_CNF" \
      --connect-timeout=15 "$@"
  fi
}

printf 'Kiểm tra kết nối VeloDB...\n'
run_mysql --batch --skip-column-names --execute='SELECT 1' >/dev/null

existing_db="$(run_mysql --batch --skip-column-names \
  --execute="SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${DB_NAME}'")"
if [[ -n "$existing_db" ]]; then
  printf 'Database %s đã tồn tại; dừng để tránh ghi đè dữ liệu.\n' "$DB_NAME" >&2
  exit 1
fi

printf 'Tạo database và 8 bảng VeloDB...\n'
run_mysql --batch < "$DDL_FILE"

printf 'Kiểm tra các bảng...\n'
actual_tables="$(run_mysql --database="$DB_NAME" --batch --skip-column-names \
  --execute='SHOW TABLES')"
for table in account session shield stat member buy app hash; do
  if ! grep -Fxq "${DB_PREFIX}${table}" <<< "$actual_tables"; then
    printf 'Thiếu bảng %s; không tạo admin.\n' "${DB_PREFIX}${table}" >&2
    exit 1
  fi
done

admin_password="$(openssl rand -hex 24)"
admin_hash="$(printf '%s' "$admin_password" | md5sum | awk '{print $1}')"
printf "INSERT INTO \`%saccount\` (\`name\`,\`pw\`,\`ip\`,\`date\`) VALUES ('%s','%s','127.0.0.1',NOW());\n" \
  "$DB_PREFIX" "$ADMIN_NAME" "$admin_hash" |
  run_mysql --database="$DB_NAME" --batch

printf 'Xác nhận tài khoản admin...\n'
created_admin="$(run_mysql --database="$DB_NAME" --batch --skip-column-names \
  --execute="SELECT name FROM \`${DB_PREFIX}account\` WHERE name='${ADMIN_NAME}' LIMIT 1")"
if [[ "$created_admin" != "$ADMIN_NAME" ]]; then
  printf 'Không xác nhận được tài khoản admin.\n' >&2
  exit 1
fi

printf '\nHoàn tất. Thông tin đăng nhập website:\n'
printf 'Tên đăng nhập: %s\nMật khẩu: %s\n' "$ADMIN_NAME" "$admin_password"
printf '\nCấu hình ứng dụng cần dùng DB_HOST=%s DB_PORT=%s DB_USER=%s DB_NAME=%s DB_TABLE_PREFIX=%s\n' \
  "$DB_HOST" "$DB_PORT" "$DB_USER" "$DB_NAME" "$DB_PREFIX"
printf 'Lưu mật khẩu admin an toàn; script không lưu mật khẩu này vào file.\n'
