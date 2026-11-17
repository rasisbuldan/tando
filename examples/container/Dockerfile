# A tiny web app image for the tando container recipe: busybox httpd on alpine (about 9 MB).
# It listens on $PORT (tando sets it) and serves /www; /www/data is the app's data volume.
FROM alpine:3.22
RUN apk add --no-cache busybox-extras
COPY www /www
CMD ["/bin/sh", "-c", "exec httpd -f -v -p 0.0.0.0:${PORT:-8080} -h /www"]
