FROM swift:6.2-noble AS build
WORKDIR /build
RUN apt-get update && apt-get install -y --no-install-recommends libssl-dev zlib1g-dev && rm -rf /var/lib/apt/lists/*
COPY Package.swift Package.resolved ./
COPY Sources/CZlib ./Sources/CZlib
RUN swift package resolve
COPY Sources ./Sources
RUN swift build -c release --disable-automatic-resolution --static-swift-stdlib -j 2
RUN mkdir /output && cp .build/release/asc-mcp /output/ && cp -R .build/release/asc-mcp_asc-mcp.resources /output/ || \
    (mkdir -p /output && cp .build/release/asc-mcp /output/ && cp -R .build/release/asc-mcp_asc-mcp.bundle /output/)

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libcurl4t64 libxml2 libicu74 zlib1g libssl3t64 libatomic1 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /output/ ./
ENV ASC_TRANSPORT=http MCP_DATA_DIR=/data PORT=8080
EXPOSE 8080
ENTRYPOINT ["/app/asc-mcp", "--http"]
