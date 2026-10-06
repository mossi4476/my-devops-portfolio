FROM public.ecr.aws/docker/library/docker:27-cli AS dockercli

FROM public.ecr.aws/docker/library/debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash curl ca-certificates procps postgresql-client tzdata coreutils diffutils \
 && rm -rf /var/lib/apt/lists/*
# Chỉ lấy docker CLI (không cài daemon) để check/restart container qua docker.sock
COPY --from=dockercli /usr/local/bin/docker /usr/local/bin/docker
ENV TZ=Asia/Ho_Chi_Minh
WORKDIR /opt/hc
