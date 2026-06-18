{{WEB_ROOT}}/{{DOMAIN}}/logs/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 640 {{WEB_USER}} {{WEB_USER}}
    sharedscripts
    postrotate
        systemctl reload php{{PHP_VERSION}}-fpm > /dev/null 2>&1 || true
        systemctl reload nginx > /dev/null 2>&1 || true
    endscript
}
