# Development instructions

- Respond in the user’s chosen language. Write code comments in English.
- Preserve all upstream tools, schemas, worker routing, result fields and recovery safeguards.
- Document new public methods with description, Returns and Throws.
- HTTP runs natively in Swift; never introduce an internal stdio bridge.
- Build and test before publishing. Exercise HTTP functionality as real MCP JSON-RPC, including failure paths.
- The cloud server is tested as a separate process; changes do not require reloading the source repository’s installed MCP.
- Never commit credentials, private keys, uploaded assets or runtime state.
