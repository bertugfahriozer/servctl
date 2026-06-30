[Unit]
Description=srvctl PHP-FPM ({{DOMAIN}})
After=network.target

[Service]
Type=notify
ExecStart=/usr/sbin/php-fpm{{PHP_VERSION}} --nodaemonize --fpm-config /etc/srvctl/fpm/{{SAFE_NAME}}.conf
ExecReload=/bin/kill -USR2 $MAINPID
Slice=srvctl-{{SAFE_NAME}}.slice
AppArmorProfile=srvctl-{{SAFE_NAME}}
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
