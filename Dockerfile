# Build stage: compile the Nim binary
FROM nimlang/nim:2.2.4-alpine-regular AS build
WORKDIR /app
COPY counter.nimble .
RUN nimble install -y --depsOnly
COPY counter.nim .
RUN nimble build -y -d:release --opt:speed

# Runtime stage: same Alpine release as the build image, so musl matches.
# The SQLite library is copied from the build image (no apk needed).
FROM alpine:3.20
RUN adduser -D -u 1000 app && mkdir -p /data && chown app:app /data
COPY --from=build /usr/lib/libsqlite3.so.0* /usr/lib/
COPY --from=build /app/counter /usr/local/bin/counter
USER app
ENV DB_PATH=/data/counter.db PORT=8000
EXPOSE 8000
CMD ["counter"]
