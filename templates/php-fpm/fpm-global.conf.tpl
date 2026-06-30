; ═══════════════════════════════════════════════
;  srvctl per-domain FPM master — {{DOMAIN}}
;  (pool bölümü pool.conf.tpl'den eklenir)
; ═══════════════════════════════════════════════
[global]
pid = /run/srvctl/fpm-{{SAFE_NAME}}.pid
error_log = {{WEB_ROOT}}/{{DOMAIN}}/logs/php-fpm-master.log
daemonize = no
