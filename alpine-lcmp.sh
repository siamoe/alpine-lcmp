#!/bin/bash
#
# LCMP (Linux + Caddy + MariaDB + PHP+Redis) Installation Script

# 设置错误处理
set -e
trap _exit INT QUIT TERM

# 颜色定义
_red() {
    printf '\033[1;31;31m%b\033[0m' "$1"
}

_green() {
    printf '\033[1;31;32m%b\033[0m' "$1"
}

_yellow() {
    printf '\033[1;31;33m%b\033[0m' "$1"
}

_blue() {
    printf '\033[1;31;34m%b\033[0m' "$1"
}

_warn() {
  echo -e "\033[33m[WARN] $1\033[0m"
}

_success() {
  echo -e "\033[32m[SUCCESS] $1\033[0m"
}
# 信息保存目录
   if [ ! -d /opt/lcmp/ ]; then
  _warn "/opt/lcmp/ 目录不存在，正在创建..."
  mkdir -p /opt/lcmp/
  if [ $? -eq 0 ]; then
    _success "/opt/lcmp/ 目录已创建"
  else
    _error "创建 /opt/lcmp/ 目录失败"
  fi
else
    _success "/opt/lcmp/ 目录已存在"
fi

# 日志函数
_printargs() {
    printf -- "%s" "[$(date '+%Y-%m-%d %H:%M:%S')] "
    printf -- "%s" "$1"
    printf "\n"
}

_info() {
    _printargs "$@"
}

_warn() {
    printf -- "%s" "[$(date '+%Y-%m-%d %H:%M:%S')] "
    _yellow "$1"
    printf "\n"
}

_error() {
    printf -- "%s" "[$(date '+%Y-%m-%d %H:%M:%S')] "
    _red "$1"
    printf "\n"
    exit 2
}

_success() {
    printf -- "%s" "[$(date '+%Y-%m-%d %H:%M:%S')] "
    _green "$1"
    printf "\n"
}

# 错误处理函数
_exit() {
    printf "\n"
    _red "$0 已终止。"
    printf "\n"
    exit 1
}

# 命令存在检查
_exists() {
    local cmd="$1"
    if eval type type >/dev/null 2>&1; then
        eval type "$cmd" >/dev/null 2>&1
    elif command >/dev/null 2>&1; then
        command -v "$cmd" >/dev/null 2>&1
    else
        which "$cmd" >/dev/null 2>&1
    fi
    local rt=$?
    return ${rt}
}

# 增强的错误检测
_error_detect() {
    local cmd="$1"
    local output
    _info "执行: ${cmd}"
    output=$(eval "${cmd}" 2>&1)
    local ret=$?
    if [ $ret -ne 0 ]; then
        _error "执行命令 (${cmd}) 失败，错误信息：${output}"
    fi
    return $ret
}

# 密码强度检查
check_password_strength() {
    local password="$1"
    if [ ${#password} -lt 8 ]; then
        _error "密码长度必须至少为8个字符"
        return 1
    fi
    if ! echo "$password" | grep -q "[A-Z]"; then
        _error "密码必须包含至少一个大写字母"
        return 1
    fi
    if ! echo "$password" | grep -q "[a-z]"; then
        _error "密码必须包含至少一个小写字母"
        return 1
    fi
    if ! echo "$password" | grep -q "[0-9]"; then
        _error "密码必须包含至少一个数字"
        return 1
    fi
    if ! echo "$password" | grep -q "[!@#$%^&*()]"; then
        _error "密码必须包含至少一个特殊字符 (!@#$%^&*())"
        return 1
    fi
    return 0
}

# 系统检查
check_sys() {
    if [ -f /etc/alpine-release ]; then
        return 0
    else
        return 1
    fi
}

# 获取用户输入
get_char() {
    SAVEDSTTY=$(stty -g)
    stty -echo
    stty cbreak
    dd if=/dev/tty bs=1 count=1 2>/dev/null
    stty -raw
    stty echo
    stty "${SAVEDSTTY}"
}

# 备份功能
backup_system() {
    local backup_dir="/opt/lcmp/lcmp_backups"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${backup_dir}/backup_${timestamp}.tar.gz"
    
    mkdir -p "${backup_dir}"
    
    _info "开始系统备份..."
    
    # 创建临时目录用于备份
    local temp_dir=$(mktemp -d)
    
    # 复制需要备份的文件到临时目录
    mkdir -p "${temp_dir}/etc"
    mkdir -p "${temp_dir}/data"
    mkdir -p "${temp_dir}/root"
    
    # 备份配置文件
    [ -d /etc/caddy ] && cp -r /etc/caddy "${temp_dir}/etc/"
    [ -d /etc/php* ] && cp -r /etc/php* "${temp_dir}/etc/"
    [ -d /etc/my.cnf.d ] && cp -r /etc/my.cnf.d "${temp_dir}/etc/"
    [ -d /data/www ] && cp -r /data/www "${temp_dir}/data/"
    
    # 备份数据库密码文件
    if [ -f /opt/lcmp/.lcmp_db_pass ]; then
        cp /opt/lcmp/.lcmp_db_pass "${temp_dir}/root/"
    fi
    
    # 备份其他信息文件
    for info_file in /opt/lcmp/.*_info; do
        if [ -f "${info_file}" ]; then
            cp "${info_file}" "${temp_dir}/root/"
        fi
    done
    
    # 创建备份文件
    cd "${temp_dir}"
    tar -czf "${backup_file}" .
    
    # 清理临时目录
    rm -rf "${temp_dir}"
    
    _success "系统备份完成：${backup_file}"
}

# 日志轮转配置
setup_log_rotation() {
    _info "配置日志轮转..."
    
    cat > /etc/logrotate.d/lcmp <<EOF
/var/log/caddy/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 644 caddy caddy
    postrotate
        /etc/init.d/caddy reload
    endscript
}

/var/log/php*/error.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 644 caddy caddy
    postrotate
        /etc/init.d/php-fpm reload
    endscript
}
EOF

    _success "日志轮转配置完成"
}

# PHP性能优化
optimize_php_performance() {
    local php_ver="$1"
    local php_pkg_ver="${php_ver/./}"
    local php_ini="/etc/php${php_pkg_ver}/php.ini"
    
    _info "优化PHP性能配置..."
    
    # 优化PHP-FPM配置
    cat > "/etc/php${php_pkg_ver}/php-fpm.d/www.conf" <<EOF
[www]
user = caddy
group = caddy
listen = /run/php-fpm.sock
listen.owner = caddy
listen.group = caddy
listen.mode = 0660
pm = dynamic
pm.max_children = 50
pm.start_servers = 5
pm.min_spare_servers = 5
pm.max_spare_servers = 35
pm.max_requests = 500
EOF

    # 优化PHP配置
    sed -i "s|^memory_limit =.*|memory_limit = 256M|" ${php_ini}
    sed -i "s|^max_execution_time =.*|max_execution_time = 300|" ${php_ini}
    sed -i "s|^opcache.enable =.*|opcache.enable = 1|" ${php_ini}
    sed -i "s|^opcache.memory_consumption =.*|opcache.memory_consumption = 128|" ${php_ini}
    sed -i "s|^opcache.interned_strings_buffer =.*|opcache.interned_strings_buffer = 8|" ${php_ini}
    sed -i "s|^opcache.max_accelerated_files =.*|opcache.max_accelerated_files = 10000|" ${php_ini}
    sed -i "s|^opcache.revalidate_freq =.*|opcache.revalidate_freq = 60|" ${php_ini}
    sed -i "s|^opcache.fast_shutdown =.*|opcache.fast_shutdown = 1|" ${php_ini}
    
    _success "PHP性能优化完成"
}



# 安装日志
log_installation() {
    local log_file="/var/log/lcmp_install.log"
    {
        echo "LCMP Installation Log"
        echo "===================="
        echo "Date: $(date)"
        echo "System: $(uname -a)"
        echo "MariaDB Version: ${mariadb_ver}"
        echo "PHP Version: ${php_ver}"
        echo "Installation Steps:"
        echo "1. System Check"
        echo "2. Package Installation"
        echo "3. Service Configuration"
        echo "4. Security Setup"
        echo "===================="
    } > "${log_file}"
}

# 主安装函数
install_lcmp() {
    # 检查用户权限
    [ ${EUID} -ne 0 ] && _error "此脚本必须以root身份运行！"
    # 检查并删除Caddy
    if command -v caddy >/dev/null 2>&1; then
        _warn "检测到Caddy，正在停止并删除..."
        rc-service caddy stop 2>/dev/null
        apk del caddy --purge 2>/dev/null
        rm -rf /etc/caddy /var/www 2>/dev/null
        _success "Caddy已删除"
    fi

    # 检查并删除MariaDB
    if command -v mariadb >/dev/null 2>&1; then
        _warn "检测到MariaDB，正在停止并删除..."
        rc-service mariadb stop 2>/dev/null
        apk del mariadb mariadb-client --purge 2>/dev/null
        rm -rf /var/lib/mysql /etc/my.cnf.d 2>/dev/null
        _success "MariaDB已删除"
    fi

    # 检查并删除PHP
    php_pkg_ver="${php_ver/./}"
    if command -v php${php_pkg_ver} >/dev/null 2>&1; then
        _warn "检测到PHP，正在停止并删除..."
        # 检查并停止 PHP-FPM 服务
        if rc-service php-fpm${php_ver/./} status >/dev/null 2>&1; then
            rc-service php-fpm${php_ver/./} stop 2>/dev/null
        fi
        apk del php${php_pkg_ver} php${php_pkg_ver}-fpm php${php_pkg_ver}-* --purge 2>/dev/null
        rm -rf /etc/php${php_ver/./} /var/log/php${php_ver/./} 2>/dev/null
        _success "PHP已删除"
    fi

    # 检查并删除Redis
    if command -v redis-server >/dev/null 2>&1; then
        _warn "检测到Redis，正在停止并删除..."
        rc-service redis stop 2>/dev/null
        apk del redis --purge 2>/dev/null
        rm -rf /var/lib/redis /etc/redis.conf 2>/dev/null
        _success "Redis已删除"
    fi

    _info "环境检查完成，开始安装..."
    # 检查系统
    if ! check_sys; then
        _error "不支持的操作系统，请使用 Alpine Linux 并重试。"
    fi

    # 选择MariaDB版本
    while true; do
        _info "请选择 MariaDB 版本:"
        _info "$(_green 1). MariaDB 10.11"
        _info "$(_green 2). MariaDB 11.4"
        read -r -p "[$(date '+%Y-%m-%d %H:%M:%S')] 请输入数字: (默认 1) " mariadb_version
        [ -z "${mariadb_version}" ] && mariadb_version=1
        case "${mariadb_version}" in
        1)
            mariadb_ver="10.11"
            break
            ;;
        2)
            mariadb_ver="11.4"
            break
            ;;
        *)
            _info "输入错误！请只输入数字 1 或 2"
            ;;
        esac
    done
    _info "---------------------------"
    _info "MariaDB 版本 = $(_red "${mariadb_ver}")"
    _info "---------------------------"

    # 设置MariaDB root密码
_info "正在生成MariaDB root密码..."
db_pass=$(openssl rand -base64 16)

_info "---------------------------"
_info "密码 = $(_red "${db_pass}")"
_info "---------------------------"

# 保存数据库密码到文件
echo "${db_pass}" > /opt/lcmp/.lcmp_db_pass
chmod 600 /opt/lcmp/.lcmp_db_pass

    # 选择PHP版本
    while true; do
        _info "请选择 PHP 版本:"
        _info "$(_green 1). PHP 8.2"
        _info "$(_green 2). PHP 8.3"
        _info "$(_green 3). PHP 8.4"
        read -r -p "[$(date '+%Y-%m-%d %H:%M:%S')] 请输入数字: (默认 3) " php_version
        [ -z "${php_version}" ] && php_version=3
        case "${php_version}" in
        1)
            php_ver="8.2"
            break
            ;;
        2)
            php_ver="8.3"
            break
            ;;
        3)
            php_ver="8.4"
            break
            ;;    
        *)
            _info "输入错误！请只输入数字 1 2 3 4"
            ;;
        esac
    done
    _info "---------------------------"
    _info "PHP 版本 = $(_red "${php_ver}")"
    _info "---------------------------"

    _info "按任意键开始安装...或按 Ctrl+C 取消"
    char=$(get_char)

    # 开始安装
    _info "开始安装 LCMP..."
    
    # 系统初始化
    _info "系统初始化..."
    _error_detect "rm -f /etc/localtime"
    _error_detect "ln -s /usr/share/zoneinfo/Asia/Shanghai /etc/localtime"

    # 基础包安装
    _info "安装基础包..."
    _error_detect "apk update"
    _error_detect "apk add --no-cache vim tar zip unzip net-tools bind-tools screen git virt-what wget whois mtr traceroute iftop htop jq tree curl"

    # 安装Caddy
    _info "安装 Caddy..."
    _error_detect "apk add --no-cache caddy"
    _success "Caddy 安装完成"

    # 安装MariaDB
    _info "安装 MariaDB..."
    _error_detect "apk add --no-cache mariadb mariadb-client mariadb-server-utils"
    _success "MariaDB 安装完成"

    # 安装PHP及扩展
    _info "安装 PHP 及扩展..."
    php_pkg_ver="${php_ver/./}"
    _error_detect "apk add --no-cache php${php_pkg_ver} php${php_pkg_ver}-fpm"

    # 安装PHP扩展
    php_extensions="mysqli json openssl curl zlib xml phar intl dom xmlreader ctype session mbstring gd opcache pdo pdo_mysql tokenizer fileinfo redis"
    for ext in ${php_extensions}; do
        _error_detect "apk add --no-cache php${php_pkg_ver}-${ext}"
    done

    # 创建php的软连接
    if [ -f /usr/bin/php${php_pkg_ver} ]; then
        _info "创建 php 软连接..."
        _error_detect "ln -sf /usr/bin/php${php_pkg_ver} /usr/bin/php"
    fi
    restart_php_fpm() {
    local php_ver=$(php -v 2>/dev/null | head -n1 | cut -d' ' -f2 | cut -d'.' -f1,2 | tr -d '.')
    if ! /etc/init.d/php-fpm${php_ver} status >/dev/null 2>&1; then
        _warn "PHP-FPM 服务已停止，正在尝试重启..."
        if /etc/init.d/php-fpm${php_ver} restart >/dev/null 2>&1; then
            _success "PHP-FPM 服务已成功重启"
        else
            _error "PHP-FPM 服务重启失败，请检查日志"
        fi
    fi
}

    # 检查PHP安装
    if ! command -v php >/dev/null 2>&1; then
        _error "PHP 安装失败，请检查安装日志"
    fi


 # 检查PHP安装
    if ! command -v php >/dev/null 2>&1; then
        _error "PHP 安装失败，请检查安装日志"
    fi
    # 安装Redis
    _info "安装 Redis..."
    _error_detect "apk add --no-cache redis"
    _error_detect "rc-update add redis default"
    _error_detect "/etc/init.d/redis start"
    _success "Redis 安装完成"

    # 安装ICU数据包
    _error_detect "apk add --no-cache icu-data-full"
    _success "PHP ${php_ver} 及扩展安装完成"

    # 创建必要的目录
    _info "创建必要的目录..."
    _error_detect "mkdir -p /data/www/default"
    _error_detect "mkdir -p /var/log/caddy/"
    _error_detect "mkdir -p /etc/caddy/conf.d/"
    _error_detect "chown -R caddy:caddy /var/log/caddy/"

    # 配置Caddy
    _info "配置 Caddy..."
    cat >/etc/caddy/Caddyfile <<EOF
{
    admin off
}
import /etc/caddy/conf.d/*.conf
EOF

    # 配置默认站点
    cat >/etc/caddy/conf.d/default.conf <<EOF
:80 {
    header {
        Strict-Transport-Security "max-age=31536000; preload"
        X-Content-Type-Options nosniff
        X-Frame-Options SAMEORIGIN
    }
    root * /data/www/default
    encode gzip
    php_fastcgi unix//run/php-fpm.sock
    file_server {
        index index.html index.php
    }
    log {
        output file /var/log/caddy/access.log {
            roll_size 100mb
            roll_keep 3
            roll_keep_for 7d
        }
    }
}
EOF
# 添加创建默认页面的函数
create_default_page() {
    local default_page="/data/www/default/index.php"
    # 检查目录是否存在
    if [ ! -d /data/www/default/ ]; then
        mkdir -p /data/www/default/
    fi
    cat > "${default_page}" << EOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>LCMP - Alpine Linux</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
            line-height: 1.6;
            margin: 0;
            padding: 20px;
            background: #f5f5f5;
        }
        .container {
            max-width: 1000px;
            margin: 0 auto;
            background: white;
            padding: 20px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        h1 { color: #2c3e50; border-bottom: 2px solid #eee; padding-bottom: 10px; }
        .info-section { margin: 20px 0; }
        .info-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
            gap: 20px;
            margin-top: 20px;
        }
        .info-box {
            background: #f8f9fa;
            padding: 15px;
            border-radius: 6px;
            border: 1px solid #dee2e6;
        }
        .info-box h3 { margin-top: 0; color: #0056b3; }
        table { width: 100%; border-collapse: collapse; }
        th, td { padding: 8px; text-align: left; border-bottom: 1px solid #ddd; }
        th { background-color: #f8f9fa; }
        .success { color: #28a745; }
        .warning { color: #ffc107; }
        .error { color: #dc3545; }
    </style>
</head>
<body>
    <div class="container">
        <h1>LCMP 服务器信息</h1>
        <div class="info-grid">
            <div class="info-box">
                <h3>系统信息</h3>
                <table>
                    <tr><td>操作系统</td><td><?php echo php_uname('s') . ' ' . php_uname('r'); ?></td></tr>
                    <tr><td>服务器时间</td><td><?php echo date('Y-m-d H:i:s'); ?></td></tr>
                    <tr><td>Caddy 版本</td><td><?php echo trim(shell_exec('caddy version')); ?></td></tr>
                </table>
            </div>
            <div class="info-box">
                <h3>PHP信息</h3>
                <table>
                    <tr><td>PHP版本</td><td><?php echo PHP_VERSION; ?></td></tr>
                    <tr><td>PHP运行模式</td><td><?php echo php_sapi_name(); ?></td></tr>
                    <tr><td>Zend引擎版本</td><td><?php echo zend_version(); ?></td></tr>
                </table>
            </div>
            <div class="info-box">
                <h3>Redis信息</h3>
                <table>
                    <?php
                    if (extension_loaded('redis')) {
                        try {
                            $redis = new Redis();
                            $redis->connect('127.0.0.1', 6379);
                            $info = $redis->info();
                            echo "<tr><td>Redis版本</td><td class='success'>{$info['redis_version']}</td></tr>";
                            echo "<tr><td>连接状态</td><td class='success'>正常</td></tr>";
                            echo "<tr><td>内存使用</td><td>" . format_bytes($info['used_memory']) . "</td></tr>";
                        } catch (Exception $e) {
                            echo "<tr><td>Redis状态</td><td class='error'>连接失败</td></tr>";
                        }
                    } else {
                        echo "<tr><td>Redis扩展</td><td class='warning'>未安装</td></tr>";
                    }
                    ?>
                </table>
            </div>
        </div>
              <div class="info-section">
            <h3>MariaDB 信息</h3>
            <div class="info-box" style="width: 97%; min-width: 200px;">
                <table>
                    <?php
echo '<p>MariaDB 版本：' . shell_exec('mysql -V') . '</p>';
?>
                </table>
            </div>
        </div>
        <div class="info-section">
            <h3>已加载的PHP扩展</h3>
            <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 10px;">
                <?php
                $extensions = get_loaded_extensions();
                sort($extensions);
                foreach ($extensions as $ext) {
                    $version = phpversion($ext);
                    echo "<div class='info-box' style='margin: 0;'>";
                    echo "<strong>{$ext}</strong>";
                    echo $version ? "<br><small>v{$version}</small>" : "";
                    echo "</div>";
                }
                ?>
            </div>
        </div>
    </div>
    <?php
    function format_bytes($bytes) {
        $units = ['B', 'KB', 'MB', 'GB'];
        $bytes = max($bytes, 0);
        $pow = floor(($bytes ? log($bytes) : 0) / log(1024));
        $pow = min($pow, count($units) - 1);
        $bytes /= pow(1024, $pow);
        return round($bytes, 2) . ' ' . $units[$pow];
    }
    ?>
</body>
</html>
EOF
    chown caddy:caddy ${default_page}
    chmod 644 ${default_page}
}
    # 配置MariaDB
    _info "配置 MariaDB..."
    # 检查并创建 /etc/my.cnf.d/ 目录
    if [ ! -d /etc/my.cnf.d/ ]; then
        _warn "/etc/my.cnf.d/ 目录不存在，正在创建..."
        mkdir -p /etc/my.cnf.d/
        _success "/etc/my.cnf.d/ 目录已创建"
    fi
    cat >/etc/my.cnf.d/server.cnf <<EOF
[mysqld]
innodb_buffer_pool_size = 100M
max_allowed_packet = 1024M
net_read_timeout = 3600
net_write_timeout = 3600
character-set-server = utf8mb4

[client-mariadb]
default-character-set = utf8mb4
EOF

    # 配置PHP
    _info "配置 PHP..."
    optimize_php_performance "${php_ver}"

    # 初始化MariaDB
    _info "初始化 MariaDB..."
    /etc/init.d/mariadb stop
    rm -rf /var/lib/mysql/*
    /etc/init.d/mariadb setup
    /etc/init.d/mariadb start

    # 设置root密码
    /usr/bin/mariadb -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${db_pass}';
FLUSH PRIVILEGES;
EOF

    # 安装phpMyAdmin
    _info "安装 phpMyAdmin..."
    _error_detect "wget -qO pma.tar.gz https://dl.lamp.sh/files/pma.tar.gz"
    _error_detect "tar zxf pma.tar.gz -C /data/www/default/"
    _error_detect "rm -f pma.tar.gz"
    mysql -uroot -p"${db_pass}" </data/www/default/pma/sql/create_tables.sql
    
    # 生成 index.php 默认页
_info "生成 index.php 默认页..."

index_content="<!DOCTYPE html>
<html lang=\"zh-CN\">
<head>
    <meta charset=\"UTF-8\">
    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
    <title>LCMP - Alpine Linux</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, \"Segoe UI\", Roboto, \"Helvetica Neue\", Arial, sans-serif;
            line-height: 1.6;
            margin: 0;
            padding: 20px;
            background: #f5f5f5;
        }
        .container {
            max-width: 1000px;
            margin: 0 auto;
            background: white;
            padding: 20px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        h1 { color: #2c3e50; border-bottom: 2px solid #eee; padding-bottom: 10px; }
        .info-section { margin: 20px 0; }
        .info-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
            gap: 20px;
            margin-top: 20px;
        }
        .info-box {
            background: #f8f9fa;
            padding: 15px;
            border-radius: 6px;
            border: 1px solid #dee2e6;
        }
        .info-box h3 { margin-top: 0; color: #0056b3; }
        table { width: 100%; border-collapse: collapse; }
        th, td { padding: 8px; text-align: left; border-bottom: 1px solid #ddd; }
        th { background-color: #f8f9fa; }
        .success { color: #28a745; }
        .warning { color: #ffc107; }
        .error { color: #dc3545; }
    </style>
</head>
<body>
    <div class=\"container\">
        <h1>LCMP 服务器信息</h1>
        <div class=\"info-grid\">
            <div class=\"info-box\">
                <h3>系统信息</h3>
                <table>
                    <tr><td>操作系统</td><td><?php 
                if (file_exists('/etc/alpine-release')) {
                    $alpine_version = trim(file_get_contents('/etc/alpine-release'));
                    echo 'Alpine v' . $alpine_version;
                } else {
                    echo php_uname('s') . ' ' . php_uname('r'); 
                }
            ?></td></tr>
                    <tr><td>服务器时间</td><td><?php echo date('Y-m-d H:i:s'); ?></td></tr>
                    <tr><td>Caddy 版本</td><td><?php echo trim(shell_exec('caddy version')); ?></td></tr>
                </table>
            </div>
            <div class=\"info-box\">
                <h3>PHP信息</h3>
                <table>
                    <tr><td>PHP版本</td><td><?php echo PHP_VERSION; ?></td></tr>
                    <tr><td>PHP运行模式</td><td><?php echo php_sapi_name(); ?></td></tr>
                    <tr><td>Zend引擎版本</td><td><?php echo zend_version(); ?></td></tr>
                </table>
            </div>
            <div class=\"info-box\">
                <h3>Redis信息</h3>
                <table>
                    <?php
                    if (extension_loaded('redis')) {
                        try {
                            \$redis = new Redis();
                            \$redis->connect('127.0.0.1', 6379);
                            \$info = \$redis->info();
                            echo \"<tr><td>Redis版本</td><td class='success'>{\$info['redis_version']}</td></tr>\";
                            echo \"<tr><td>连接状态</td><td class='success'>正常</td></tr>\";
                            echo \"<tr><td>内存使用</td><td>\" . format_bytes(\$info['used_memory']) . \"</td></tr>\";
                        } catch (Exception \$e) {
                            echo \"<tr><td>Redis状态</td><td class='error'>连接失败</td></tr>\";
                        }
                    } else {
                        echo \"<tr><td>Redis扩展</td><td class='warning'>未安装</td></tr>\";
                    }
                    ?>
                </table>
            </div>
        </div>
             <div class=\"info-section\">
            <h3>MariaDB 信息</h3>
            <div class=\"info-box\" style=\"width: 97%; min-width: 200px;\">
                <table>
                    <?php
echo '<p>MariaDB 版本：' . shell_exec('mysql -V') . '</p>';
?>
                </table>
            </div>
        </div>
        <div class=\"info-section\">
            <h3>已加载的PHP扩展</h3>
            <div style=\"display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 10px;\">
                <?php
                \$extensions = get_loaded_extensions();
                sort(\$extensions);
                foreach (\$extensions as \$ext) {
                    \$version = phpversion(\$ext);
                    echo \"<div class='info-box' style='margin: 0;'>\";
                    echo \"<strong>{\$ext}</strong>\";
                    echo \$version ? \"<br><small>v{\$version}</small>\" : \"\";
                    echo \"</div>\";
                }
                ?>
            </div>
        </div>
    </div>
    <?php
    function format_bytes(\$bytes) {
        \$units = ['B', 'KB', 'MB', 'GB'];
        \$bytes = max(\$bytes, 0);
        \$pow = floor((\$bytes ? log(\$bytes) : 0) / log(1024));
        \$pow = min(\$pow, count(\$units) - 1);
        \$bytes /= pow(1024, \$pow);
        return round(\$bytes, 2) . ' ' . \$units[\$pow];
    }
    ?>
</body>
</html>"

echo "${index_content}" > /data/www/default/index.php

_success "index.php 默认页已生成。"

    # 设置目录权限
    _error_detect "chown -R caddy:caddy /data/www"

    # 添加服务到开机启动
    _info "配置服务自启动..."
    _error_detect "rc-update add mariadb default"
    _error_detect "rc-update add php-fpm${php_pkg_ver} default"
    _error_detect "rc-update add caddy default"

    # 启动服务
    _info "启动服务..."
    _error_detect "/etc/init.d/mariadb restart"
    _error_detect "/etc/init.d/php-fpm${php_pkg_ver} restart"
    _error_detect "/etc/init.d/caddy restart"

    # 配置日志轮转
    setup_log_rotation

    # 创建备份
    backup_system
    
    # 监控配置
setup_monitoring() {
    _info "配置监控..."
    apk add --no-cache telegraf
    cat > /etc/telegraf.conf <<EOF
[global_tags]
  host = "\$(hostname)"

[agent]
  interval = "10s"
  round_interval = true
  metric_batch_size = 1000
  metric_buffer_limit = 10000
  collection_jitter = "0s"
  flush_interval = "10s"
  flush_jitter = "0s"
  precision = "1s"
  omit_hostname = false

[[inputs.cpu]]
  percpu = true
  totalcpu = true
  collect_cpu_time = false
  report_per_cpu = false

[[inputs.disk]]
  ignore_fs = ["tmpfs", "devtmpfs", "overlay", "aufs", "squashfs"]

[[inputs.diskio]]

[[inputs.mem]]

[[inputs.net]]

[[inputs.swap]]

[[inputs.system]]

[[inputs.mysql]]
  servers = ["root:\$(cat /opt/lcmp/.lcmp_db_pass)@tcp(127.0.0.1:3306)/"]

[[inputs.redis]]
  servers = ["tcp://127.0.0.1:6379"]

[[outputs.file]]
  files = ["/var/log/telegraf.log"]
  data_format = "influx"
EOF
    rc-update add telegraf default
    /etc/init.d/telegraf start
    _success "监控配置完成"
}

    # 记录安装日志
    log_installation

verify_services() {
    local error=0
    
    # 检查MariaDB
    if ! mysqladmin ping >/dev/null 2>&1; then
        _red "MariaDB 连接失败\n"
        error=1
    fi
    
    # 检查PHP-FPM
    if ! test -S /run/php-fpm.sock; then
        _red "PHP-FPM socket不存在\n"
        error=1
    fi
    
    # 检查Caddy
    if ! netstat -tnlp | grep -q ':80'; then
        _red "Caddy未监听80端口\n"
        error=1
    fi
    
    # 检查Redis
    if ! redis-cli ping >/dev/null 2>&1; then
        _red "Redis 连接失败\n"
        error=1
    fi
    
    if [ $error -eq 1 ]; then
        _warn "某些服务可能未正常运行，请检查日志文件:"
        _info "MariaDB: /var/log/mysql/error.log"
        _info "PHP-FPM: /var/log/php${php_pkg_ver}/error.log"
        _info "Caddy: /var/log/caddy/access.log"
        _info "Redis: /var/log/redis/redis.log"
    fi
}
verify_services
show_status() {
    _info "系统状态信息:"
    _info "------------------------"

    # 显示服务状态
    _info "服务状态:"
    check_service_status mariadb
    local php_ver=$(php -v 2>/dev/null | head -n1 | cut -d' ' -f2 | cut -d'.' -f1,2 | tr -d '.')
    check_service_status "php-fpm${php_ver}"
    check_service_status caddy
    check_service_status redis

    # 显示磁盘使用
    _info "磁盘使用:"
    df -h / /data | awk '!seen[$0]++' | sed 's/^/  /'
}
    _success "LCMP 安装完成！"
    _info "------------------------"
    _info "Web根目录: $(_green "/data/www")"
    _info "默认站点: $(_green "http://$(curl -s ip.sb)")"
    _info "phpMyAdmin: $(_green "http://$(curl -s ip.sb)/pma/")"
    _info "MariaDB root密码: $(_green "${db_pass}")"
    _info "------------------------"
}

# 执行安装
install_lcmp 

# 创建LCMP管理脚本
cat >/usr/local/bin/lcmp <<'EOF'
#!/bin/bash

# 颜色定义
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
RESET=$(tput sgr0)

# 信息输出
_info() {
    printf "[%s] %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1"
}

# 服务状态检查
check_service_status() {
    local service=$1
    if /etc/init.d/${service} status >/dev/null 2>&1; then
        printf "%-20s: %s%s%s\n" "$service" "${GREEN}运行正常${RESET}" "" ""
    else
        printf "%-20s: %s%s%s\n" "$service" "${RED}运行异常${RESET}" "" ""
    fi
}

# 显示帮助信息
show_help() {
    echo "LCMP 管理工具"
    echo
    echo "用法: lcmp [命令] [参数]"
    echo
    echo "系统状态命令:"
    echo "  status                     显示所有服务状态"
    echo "  status:web                 显示网站相关服务状态"
    echo "  status:db                  显示数据库状态"
    echo
    echo "网站管理命令:"
    echo "  add    <域名>              添加新网站"
    echo "  del    <域名>              删除网站"
    echo "  list                       列出所有网站"
    echo
    echo "数据库管理命令:"
    echo "  db:create  <数据库名>      创建新数据库"
    echo "  db:delete  <数据库名>      删除数据库"
    echo "  db:list                    列出所有数据库"
    echo
    echo "帮助信息:"
    echo "  help                       显示此帮助信息"
    echo
    echo "示例:"
    echo "  lcmp add example.com"
    echo "  lcmp db:create mydb"
}

# 添加网站
add_site() {
    local domain=$1
    if [ -z "${domain}" ]; then
        _info "${RED}请指定域名!${RESET}"
        return 1
    fi
    
    # 创建网站目录
    mkdir -p "/data/www/${domain}"
    chown -R caddy:caddy "/data/www/${domain}"
    
    # 创建网站配置
    cat > "/etc/caddy/conf.d/${domain}.conf" <<CONF
${domain} {
    header {
        Strict-Transport-Security "max-age=31536000; preload"
        X-Content-Type-Options nosniff
        X-Frame-Options SAMEORIGIN
    }
    root * /data/www/${domain}
    encode gzip
    php_fastcgi unix//run/php-fpm.sock
    file_server {
        index index.html index.php
    }
    log {
        output file /var/log/caddy/${domain}.log {
            roll_size 100mb
            roll_keep 3
            roll_keep_for 7d
        }
    }
}
CONF
    
    # 创建默认首页
    cat > "/data/www/${domain}/index.php" <<PHP
<!DOCTYPE html>
<html>
<head>
    <title>Welcome to ${domain}</title>
</head>
<body>
    <h1>Welcome to ${domain}</h1>
    <p>PHP Version: <?php echo PHP_VERSION; ?></p>
</body>
</html>
PHP
    
    # 重启Caddy服务
    /etc/init.d/caddy restart
    
    _info "${GREEN}网站 ${domain} 添加成功!${RESET}"
}

# 删除网站
del_site() {
    local domain=$1
    if [ -z "${domain}" ]; then
        _info "${RED}请指定域名!${RESET}"
        return 1
    fi
    
    # 删除网站目录和配置
    rm -rf "/data/www/${domain}"
    rm -f "/etc/caddy/conf.d/${domain}.conf"
    rm -f "/var/log/caddy/${domain}.log"*
    
    # 重启Caddy服务
    /etc/init.d/caddy restart
    
    _info "${GREEN}网站 ${domain} 删除成功!${RESET}"
}

# 列出网站
list_sites() {
    _info "已配置的网站:"
    for conf in /etc/caddy/conf.d/*.conf; do
        if [ -f "${conf}" ] && [ "${conf}" != "/etc/caddy/conf.d/default.conf" ]; then
            printf "  - %s\n" "$(basename "${conf}" .conf)"
        fi
    done
}

# 数据库操作
db_execute() {
    local sql="$1"
    local password
    
    if [ ! -f /opt/lcmp/.lcmp_db_pass ]; then
        _info "${RED}数据库密码文件不存在!${RESET}"
        return 1
    fi
    
    password=$(cat /opt/lcmp/.lcmp_db_pass)
    if [ -z "${password}" ]; then
        _info "${RED}数据库密码为空!${RESET}"
        return 1
    fi
    
    # 执行SQL命令
    /usr/bin/mariadb -uroot -p"${password}" -e "$sql" 2>/dev/null
    local ret=$?
    if [ $ret -ne 0 ]; then
        return 1
    fi
    return 0
}

# 生成密码
generate_password() {
    local length=16
    tr -dc 'A-Za-z0-9!@#$%^&*()' </dev/urandom | head -c ${length}
}

# 创建数据库
create_database() {
    local dbname=$1
    if [ -z "${dbname}" ]; then
        _info "${RED}请指定数据库名!${RESET}"
        return 1
    fi
    
    # 生成用户名和密码
    local username="${dbname}_user"
    local password=$(generate_password)
    
    # 创建数据库
    if ! db_execute "CREATE DATABASE \`${dbname}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"; then
        _info "${RED}数据库 ${dbname} 创建失败!${RESET}"
        return 1
    fi
    
    # 创建用户
    if ! db_execute "CREATE USER '${username}'@'localhost' IDENTIFIED BY '${password}';"; then
        _info "${RED}用户 ${username} 创建失败!${RESET}"
        db_execute "DROP DATABASE \`${dbname}\`;"
        return 1
    fi
    
    # 授予权限
    if ! db_execute "GRANT ALL PRIVILEGES ON \`${dbname}\`.* TO '${username}'@'localhost'; FLUSH PRIVILEGES;"; then
        _info "${RED}授权失败!${RESET}"
        db_execute "DROP USER '${username}'@'localhost';"
        db_execute "DROP DATABASE \`${dbname}\`;"
        return 1
    fi
    
    # 保存数据库信息到文件
    echo "数据库名：${dbname}" > "/opt/lcmp/.${dbname}_info"
    echo "用户名：${username}" >> "/opt/lcmp/.${dbname}_info"
    echo "密码：${password}" >> "/opt/lcmp/.${dbname}_info"
    chmod 600 "/opt/lcmp/.${dbname}_info"
    
    _info "${GREEN}数据库创建成功!${RESET}"
    _info "数据库名: ${dbname}"
    _info "用户名: ${username}"
    _info "密码: ${password}"
    _info "信息已保存到 /opt/lcmp/.${dbname}_info"
}

# 删除数据库
delete_database() {
    local dbname=$1
    if [ -z "${dbname}" ]; then
        _info "${RED}请指定数据库名!${RESET}"
        return 1
    fi
    
    # 获取用户名
    local username="${dbname}_user"
    
    # 删除用户
    db_execute "DROP USER IF EXISTS '${username}'@'localhost';"
    
    # 删除数据库
    if db_execute "DROP DATABASE IF EXISTS \`${dbname}\`;"; then
        # 删除信息文件
        rm -f "/opt/lcmp/.${dbname}_info"
        _info "${GREEN}数据库 ${dbname} 及其用户删除成功!${RESET}"
    else
        _info "${RED}数据库 ${dbname} 删除失败!${RESET}"
        return 1
    fi
}

# 列出数据库
list_databases() {
    _info "已存在的数据库及其用户信息:"
    for info_file in /opt/lcmp/.*_info; do
        if [ -f "${info_file}" ]; then
            cat "${info_file}"
            echo "------------------------"
        fi
    done
    
    _info "所有数据库列表:"
    local password=$(cat /opt/lcmp/.lcmp_db_pass)
    /usr/bin/mariadb -uroot -p"${password}" -N -e "SHOW DATABASES;" | grep -Ev "^(information_schema|performance_schema|mysql|sys)$"
}

# 显示系统状态
show_status() {
    _info "系统状态信息:"
    
    _info "系统负载: $(uptime | awk -F'load average:' '{print $2}')"
    _info "内存使用:"
    free -h | grep -v +
    _info "磁盘使用:"
    df -h /
    _info "服务状态:"
    check_service_status mariadb
    local php_ver=$(php -v | head -n1 | cut -d' ' -f2 | cut -d'.' -f1,2 | tr -d '.')
    check_service_status "php-fpm${php_ver}"
    check_service_status caddy
    check_service_status redis
    _info "端口监听:"
    netstat -tnlp | grep -E ':(80|443|3306|6379)'
    _info "PHP 版本: $(php -v | head -n1 | cut -d' ' -f2)"
    _info "PHP-FPM 进程: $(ps aux | grep 'php-fpm' | grep -v grep | wc -l)"
    
    local db_password=$(cat /opt/lcmp/.lcmp_db_pass)
    _info "数据库连接数:"
    mariadb -uroot -p"${db_password}" -e "SHOW STATUS LIKE '%Threads_connected%';" 2>/dev/null
    
    _info "已配置网站:"
    for conf in /etc/caddy/conf.d/*.conf; do
        if [ -f "${conf}" ] && [ "${conf}" != "/etc/caddy/conf.d/default.conf" ]; then
            printf "  - %s\n" "$(basename "${conf}" .conf)"
        fi
    done
}

# 显示Web服务状态
show_web_status() {
    _info "Web服务状态:"
    
    _info "Caddy状态:"
    check_service_status caddy
    _info "PHP-FPM状态:"
    local php_ver=$(php -v | head -n1 | cut -d' ' -f2 | cut -d'.' -f1,2 | tr -d '.')
    check_service_status "php-fpm${php_ver}"
    _info "网站配置:"
    for conf in /etc/caddy/conf.d/*.conf; do
        if [ -f "${conf}" ]; then
            printf "  - %s\n" "$(basename "${conf}")"
        fi
    done
}

# 显示数据库状态
show_db_status() {
    _info "数据库状态:"
    
    check_service_status mariadb
    local db_password=$(cat /opt/lcmp/.lcmp_db_pass)
    if mariadb -uroot -p"${db_password}" -e "SELECT VERSION();" >/dev/null 2>&1; then
        _info "数据库版本: $(mariadb -V | awk '{print $5}' | cut -d',' -f1)"
        _info "数据库连接数:"
        mariadb -uroot -p"${db_password}" -e "SHOW STATUS LIKE '%Threads_connected%';" 2>/dev/null
    else
        _info "${RED}无法连接到数据库${RESET}"
    fi
}

# 命令解析
case "$1" in
    status) show_status ;;
    status:web) show_web_status ;;
    status:db) show_db_status ;;
    add) add_site "$2" ;;
    del) del_site "$2" ;;
    list) list_sites ;;
    db:create) create_database "$2" ;;
    db:delete) delete_database "$2" ;;
    db:list) list_databases ;;
    help|--help|-h) show_help ;;
    *) show_help; exit 1 ;;
esac
EOF

# 设置lcmp命令的权限
chmod +x /usr/local/bin/lcmp
