# Nginx-based frontend — serves static files and proxies to backend APIs
FROM nginx:1.27-alpine

# Upgrade all Alpine packages to pull in the latest security patches
RUN apk upgrade --no-cache

# Remove default nginx config
RUN rm /etc/nginx/conf.d/default.conf

# Copy our custom nginx config
COPY nginx.conf /etc/nginx/nginx.conf

# Copy static HTML/JS
COPY html/ /usr/share/nginx/html/

# nginx on Alpine already runs as root but switches to user after binding.
# For extra security, we run on port 8080 (non-privileged).
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:8080/health || exit 1

CMD ["nginx", "-g", "daemon off;"]
