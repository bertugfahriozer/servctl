# ═══════════════════════════════════════════════
#  ModSecurity Ana Yapılandırma
#  OWASP Core Rule Set (CRS) ile WAF
# ═══════════════════════════════════════════════

SecRuleEngine On
SecRequestBodyAccess On
SecResponseBodyAccess Off

# ─── Request Body ───
SecRequestBodyLimit 52428800
SecRequestBodyNoFilesLimit 131072
SecRequestBodyLimitAction Reject

# ─── Temp/Data dizinleri ───
SecTmpDir /tmp/modsecurity/tmp
SecDataDir /tmp/modsecurity/data
SecUploadDir /tmp/modsecurity/upload
SecUploadKeepFiles Off

# ─── Audit Log ───
SecAuditEngine RelevantOnly
SecAuditLogRelevantStatus "^(?:5|4(?!04))"
SecAuditLogType Serial
SecAuditLog /var/log/nginx/modsecurity-audit.log
SecAuditLogParts ABIJDEFHZ

# ─── Debug Log (üretimde kapalı) ───
SecDebugLog /var/log/nginx/modsecurity-debug.log
SecDebugLogLevel 0

# ─── Varsayılan Kurallar ───
SecRule REQUEST_HEADERS:Content-Type "(?:application(?:/soap\+|/)|text/)xml" \
    "id:200000,phase:1,t:none,t:lowercase,pass,nolog,ctl:requestBodyProcessor=XML"
SecRule REQUEST_HEADERS:Content-Type "application/json" \
    "id:200001,phase:1,t:none,t:lowercase,pass,nolog,ctl:requestBodyProcessor=JSON"

# ─── OWASP CRS Yükle ───
Include /etc/nginx/owasp-crs/crs-setup.conf
Include /etc/nginx/owasp-crs/rules/*.conf

# ─── Özel Kurallar (False Positive Temizliği) ───
# CI4 CSRF token uzun olabilir
SecRule REQUEST_HEADERS:Content-Type "application/x-www-form-urlencoded" \
    "id:200010,phase:1,t:none,nolog,pass,ctl:requestBodyProcessor=URLENCODED"

# CI4 admin: yalnız bilinen yanlış-pozitif XSS kuralı (941160 — zengin-metin
# alanlarında HTML-injection checker). XSS ailesinin (941xxx) geri kalanı /admin/
# için de AKTİF kalır; operatör ihtiyaca göre ek ID ekleyebilir.
SecRule REQUEST_URI "@beginsWith /admin/" \
    "id:200020,phase:1,t:none,nolog,pass,ctl:ruleRemoveById=941160"
