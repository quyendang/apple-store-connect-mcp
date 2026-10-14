# Deploy lên Railway

Project này chạy HTTP trực tiếp trong Swift. Không có Node.js hoặc bridge qua stdio nội bộ. Giữ nguyên 502 công cụ upstream; HTTP bổ sung 5 công cụ cloud.

## Cấu hình

1. Tạo Railway service từ private repository `quyendang/apple-store-connect-mcp`. Railway sẽ dùng `Dockerfile` và `railway.toml`.
2. Gắn **Railway Volume tại `/data`**. Chạy **một replica**. Đây là điều kiện để giữ OAuth clients/tokens, file upload và job receipts qua redeploy.
3. Tạo domain Railway hoặc custom domain.
4. Thiết lập Variables:

| Variable | Giá trị |
|---|---|
| `MCP_PUBLIC_URL` | `https://domain.com` — không thêm `/mcp` |
| `MCP_ADMIN_PASSWORD` | Mật khẩu ngẫu nhiên ít nhất 24 bytes, dùng để cấp quyền OAuth |
| `ASC_COMPANIES_JSON` | JSON danh sách công ty có `key_content` chứa PEM của `.p8` |
| `MCP_DATA_DIR` | `/data` |
| `ASC_TRANSPORT` | `http` |
| `MCP_BEARER_TOKEN` | Tùy chọn, token ngẫu nhiên ít nhất 32 bytes cho CLI/Inspector |

Railway tự cấp `PORT`; server lắng nghe `0.0.0.0:$PORT`. Healthcheck: `/health/ready`.

Tạo mật khẩu/token trên máy của bạn bằng `openssl rand -hex 32`. Không commit giá trị thật.

Ví dụ cấu trúc `ASC_COMPANIES_JSON` (thay toàn bộ placeholder trong Railway Variables):

```json
{"companies":[{"id":"team1","name":"My Team","key_id":"APPLE_KEY_ID","issuer_id":"APPLE_ISSUER_ID","key_content":"-----BEGIN PRIVATE KEY-----\nPEM_CONTENT\n-----END PRIVATE KEY-----","vendor_number":"OPTIONAL_VENDOR_NUMBER"}]}
```

`key_content` dùng escaped newlines đúng cú pháp JSON. `vendor_number` cần cho sales/financial reports. Có thể cấu hình nhiều công ty; `company_switch` hoạt động trong ngữ cảnh riêng. Cloud mode chỉ gửi Apple credentials tới `https://api.appstoreconnect.apple.com`.

## Kết nối ChatGPT / Gemini

Endpoint: `https://domain.com/mcp`. Chọn OAuth. Server hỗ trợ Dynamic Client Registration (public client), Authorization Code + PKCE S256, refresh token rotation và revoke. Trong trang cấp quyền, nhập `MCP_ADMIN_PASSWORD`. Apple `.p8` không đi qua OAuth client.

Scopes: `asc:read`, `asc:write`, `asc:admin`, `offline_access`. `auth_*` cần `asc:admin`. Read-only vẫn công bố toàn bộ catalog nhưng chặn thao tác ghi trước khi chạy handler. Có thể thêm `--read-only` vào lệnh chạy server.

Nếu client gửi Origin của trang web, thêm các origin cụ thể vào `MCP_ALLOWED_ORIGINS`, phân cách bằng dấu phẩy; server luôn chấp nhận origin của `MCP_PUBLIC_URL` cho trang đăng nhập. Không dùng wildcard. CORS không thay thế OAuth.

Nếu nhập đúng mật khẩu nhưng thấy `Origin not allowed`, kiểm tra `MCP_PUBLIC_URL` trùng domain đang mở (ví dụ `https://appstore.thaybinh.ai`, không thêm `/mcp`). Trang `/oauth/authorize` phải trả header `Referrer-Policy: same-origin`; bản cũ dùng `no-referrer` khiến trình duyệt gửi `Origin: null` khi submit. Deploy commit mới rồi bắt đầu lại kết nối OAuth để tải form mới. Không thêm `null` hoặc `*` vào `MCP_ALLOWED_ORIGINS`.

Trang đăng nhập thêm origin của callback đã đăng ký và được xác thực vào CSP `form-action`, để trình duyệt cho phép redirect sau khi submit. Callback vẫn phải khớp chính xác URI đã đăng ký; không cần thêm domain callback vào `MCP_ALLOWED_ORIGINS` chỉ để hoàn thành OAuth.

Khả năng thêm custom MCP trong ChatGPT/Gemini phụ thuộc tài khoản, workspace và khu vực. Một endpoint chạy đúng không mở khóa tính năng chưa được nhà cung cấp cấp cho tài khoản. Khả năng client nhập đủ 507 công cụ cũng cần kiểm thử trên tài khoản thực; không có công cụ upstream nào bị loại bỏ để giảm catalog.

## Protocol và ngữ cảnh

- Client legacy: `initialize`, sau đó gửi `MCP-Session-Id`. POST trả SSE; GET mở SSE của SDK; DELETE kết thúc session. Những phiên bản được SDK 0.12 hỗ trợ: `2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05` trên Streamable HTTP. Không triển khai endpoint HTTP+SSE cổ điển `/sse` + `/messages`.
- Client `2026-07-28`: request có metadata và headers chuẩn; hỗ trợ `server/discover`, `tools/list`, `tools/call`. Không có transport session. Gọi `bridge_context_create`, rồi truyền `context_id` vào các lời gọi tiếp theo.
- Mỗi working context có WorkerManager, JWTService, HTTPClient và CompaniesManager riêng, tất cả trong cùng Swift process.
- Context/session là trạng thái RAM, hết hạn sau một giờ không hoạt động và mất sau restart. Tạo context mới rồi chọn lại công ty. File và job receipts vẫn tồn tại trên Volume.
- Bản này quảng bá tools capability; không quảng bá sampling, resources, prompts hay Tasks extension mà upstream không triển khai. Tác vụ nền dùng các công cụ `bridge_jobs_*`.

## Upload file

1. Gọi `bridge_files_create_upload` với `file_name`.
2. Mở `upload_url`, chọn file rồi upload. CI cũng có thể POST raw bytes tới `upload_endpoint`.
3. Kết quả trả về `file_id`, `file_path`, `file_name`, `file_size`.
4. Gọi công cụ gốc như `screenshots_upload`, `build_uploads_upload`, `review_attachments_upload` với `file_id` thay cho `file_path`. Công cụ batch nhận `file_ids` khi schema gốc có `file_paths`.

Các trường file trong object/array lồng nhau vẫn hỗ trợ đường dẫn file đã đăng ký. Server chỉ cho phép dùng file thuộc OAuth grant hiện tại, tránh đọc `.p8` và file hệ thống. Token refresh giữ nguyên grant; cấp quyền OAuth hoàn toàn mới tạo grant khác. File do grant cũ tạo không được grant mới tự động truy cập.

Link upload dùng một lần, hết hạn sau 15 phút. Giới hạn mặc định 10 GiB/file, tối đa 4 upload đồng thời; dùng `MCP_MAX_UPLOAD_BYTES` để điều chỉnh. Railway yêu cầu request body upload hoàn tất trong 5 phút: file quá lớn/chậm cần được chuyển tới server bằng một đường truyền đủ nhanh hoặc bổ sung object-storage multipart backend. Bản đầu này dùng Volume, chưa có S3 multipart upload. Không truyền file lớn dưới dạng base64 trong tool arguments.

## Tác vụ nền

`bridge_jobs_submit` nhận `tool_name`, `arguments`, `operation_id` và tùy chọn `context_id`. Chọn `operation_id` ổn định cho một thao tác. Công ty được snapshot khi submit; việc đổi công ty sau đó không đổi tài khoản của job.

`bridge_jobs_get` trả trạng thái và `original_result` nguyên vẹn: text, structuredContent, isError và metadata. Các xác nhận xóa/phát hành của công cụ gốc vẫn bắt buộc. Các công cụ auth và company_switch chạy đồng bộ.

Cùng operation_id và input trả lại job cũ; khác input trả lỗi. Server không tuyên bố exactly-once ở Apple. Nếu restart trong khi job đang chạy, trạng thái là `unknown`; inspect tài nguyên bên Apple trước khi quyết định tiếp tục. Không tự replay mutation. Job submit không hoàn thành chỉ vì server đã nhận request.

Tối đa 4 jobs chạy đồng thời, catalog tối đa 10.000 receipts. Bản đầu chưa có chức năng hủy job, cleanup assets qua MCP, multi-user tenant onboarding hoặc horizontal scaling. Khi cần các khả năng này, bổ sung riêng; các 502 công cụ upstream vẫn đầy đủ.

## Kiểm thử

```bash
swift test
swift build -c release
python3 Scripts/ci/http_mcp_smoke.py --binary .build/release/asc-mcp
```

Smoke test tạo keys giả bằng OpenSSL và gọi server qua MCP thật; không kết nối Apple. Nó kiểm tra catalog, inputs lỗi, isolated companies, file confinement, jobs, PKCE, refresh/revoke và hai chế độ giao thức.

CI kiểm tra Linux Swift 6.2, macOS và Docker image. CI không chứng minh credentials Apple thật hoặc quyền tài khoản ChatGPT/Gemini; cần integration test sau khi bạn cấu hình và deploy. Không chạy write test trên ứng dụng thật chỉ để xác nhận kết nối.

## Vận hành

- Backup Volume: `oauth.json`, `assets.json`, `jobs.json` và thư mục `assets/`.
- Không chia sẻ Volume state qua nhiều replicas; JSON stores hiện được đồng bộ bằng actor trong một process.
- SSE gửi heartbeat mỗi 15 giây và đóng trước giới hạn request 15 phút của Railway; ưu tiên job nền cho tác vụ dài.
- OAuth codes/consent flows là RAM và hết hạn ngắn. Access tokens hết hạn 1 giờ; refresh tokens 30 ngày, rotate khi sử dụng.
- Runtime state chứa dữ liệu nhạy cảm; dùng backup private. `.gitignore` và `.dockerignore` loại trừ keys, env và cloud-data.
- Để thu hồi quyền OAuth, gọi `/oauth/revoke`. Thay MCP_ADMIN_PASSWORD không tự thu hồi grants hiện có. Thay MCP_BEARER_TOKEN để vô hiệu automation token cũ.

## Nguồn upstream

Dựa trên `zelentsov-dev/asc-mcp`, commit `3081cc34dadaaee7594c3d92309eabb9fbc460e0`, giữ nguyên giấy phép MIT và attribution. Phần transport/cloud được bổ sung cho repository này.

## Chức năng công cụ cloud

| Công cụ | Trả về | Mục đích |
|---|---|---|
| `bridge_context_create` | `context_id` | Chọn công ty độc lập trong MCP không handshake |
| `bridge_files_create_upload` | Link upload, endpoint POST, expiry, giới hạn bytes | Chuyển asset từ trình duyệt/CI lên Volume |
| `bridge_files_list` | Danh sách file ID, đường dẫn, kích thước, ngày tạo | Dùng lại asset thuộc connection hiện tại |
| `bridge_jobs_submit` | Job ID, operation ID, context, trạng thái | Chạy công cụ gốc trong nền với dedupe và account snapshot |
| `bridge_jobs_get` | Trạng thái, recovery flags, kết quả gốc đầy đủ | Theo dõi tiến độ và lấy kết quả sau khi HTTP request đã kết thúc |
