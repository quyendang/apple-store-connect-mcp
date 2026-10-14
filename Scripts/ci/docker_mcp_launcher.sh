#!/bin/sh
set -eu
# The smoke runner supplies only temporary synthetic keys and owner credentials.
mkdir -p "$MCP_DATA_DIR"
exec docker run --rm --network host --user "$(id -u):$(id -g)" \
    -v "$MCP_DATA_DIR:$MCP_DATA_DIR" \
    -e MCP_PUBLIC_URL -e MCP_ADMIN_PASSWORD -e MCP_BEARER_TOKEN \
    -e PORT -e MCP_DATA_DIR -e ASC_COMPANIES_JSON -e ASC_TRANSPORT \
    apple-store-connect-mcp:ci "$@"
