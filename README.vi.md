# Search

Một trình duyệt web nhỏ, nhanh, yên tĩnh cho Mac, của [Office Commun](https://officecommun.com).

> Bản dịch tiếng Việt của [README.md](README.md).

![Search, với các tab ở bên trái và một trang chiếm phần còn lại của cửa sổ](.github/screenshot.png)

**[Tải về cho macOS →](https://officecommun.com/search)** · macOS 14 trở lên · miễn phí · khoảng 3 MB

Hoặc qua [Homebrew](https://brew.sh): `brew install --cask driceroland/tap/search`

---

## Nó là gì

Search là trình duyệt không có gì vướng bận. Một hàng tab — ngang trên cùng hoặc dọc bên trái, tùy bạn — và trang web. Không có thanh công cụ, không có trang khởi đầu, không có cột bên gợi ý, không có tài khoản để đăng nhập, không có thứ gì giành lấy sự chú ý của bạn. Bạn gõ một địa chỉ hay vài chữ vào một ô duy nhất là tới ngay trang đó.

Nó dùng **WebKit**, engine vốn đã nằm sẵn trong mọi chiếc Mac (đó là thứ Safari chạy lên). Vì thế cả ứng dụng chỉ nặng khoảng 3 MB trên đĩa và mở tức thì: không có thêm một bản Chromium thứ hai phải tải về, cập nhật và giữ trong bộ nhớ.

Nó được xây bởi một studio thiết kế cả ngày ngụp lặn trong trình duyệt và chán những trình duyệt đã biến thành "sản phẩm". Cái này là một công cụ.

## Nó làm gì

- **Một ô duy nhất.** Gõ địa chỉ thì tới đó; gõ chữ thì tìm kiếm. Nó tự hoàn thành địa chỉ dựa trên lịch sử của chính bạn và không gửi bất cứ thứ gì bạn gõ đi đâu cho tới khi bạn bấm Return.
- **Tab không làm phiền bạn.** Ghim những trang bạn mở suốt cả ngày, chúng thu lại còn một chữ cái hoặc biểu tượng. Tab từ phiên trước quay lại tức thì và không tốn thứ gì cho tới khi bạn bấm vào chúng. `⌘K` liệt kê các tab đang mở theo tên.
- **Chế độ đọc.** `⇧⌘R` lọc một trang xuống còn phần bài viết.
- **Ẩn bất cứ thứ gì, vĩnh viễn.** `⇧⌘H`, rồi bấm vào một banner cookie, một lớp phủ đăng ký bản tin, một dàn gợi ý "liên quan" vô nghĩa — nó biến mất, và lần sau trên chính trang đó nó vẫn biến mất, trước khi trang kịp vẽ một khung hình nào.
- **Trình chặn quảng cáo chạy trước trang.** Bên theo dõi và mạng quảng cáo bên thứ ba bị chặn ở tầng mạng, nên không có gì phải vẽ và không có gì làm chậm lại. Bật sẵn mặc định, tắt theo từng trang nếu có thứ gì đó hỏng.
- **Video đi theo bạn.** `⇧⌘P` đưa video ra khỏi trang thành một cửa sổ nhỏ luôn nổi trên tất cả, kể cả các ứng dụng khác.
- **Mật khẩu, trong keychain của bạn.** Search đề nghị lưu thông tin đăng nhập sau khi đăng nhập đó thật sự thành công, và liệt kê các tài khoản đã lưu ngay dưới ô khi bạn bấm vào nó — như cách Safari làm, không bao giờ tự điền gì. Mọi thứ nằm trong keychain macOS, do hệ thống mã hóa, chỉ Search được đọc. Nhập từ Chrome, Arc, Dia, Brave hay Edge chỉ bằng một cú nhấp; không thứ gì rời khỏi Mac.
- **Sáng, tối, hoặc theo chính màu của Mac.** Khung và các trang đều tuân theo.
- **Dấu trang, lịch sử, tải xuống** — mỗi thứ một bảng, mỗi bảng tìm kiếm được, mỗi thứ chỉ cách bạn một phím.
- **Tiện ích Chrome, không cần Chrome.** Dán một liên kết Chrome Web Store vào Cài đặt › Tiện ích, hoặc mở trang của tiện ích trong Search rồi bấm Thêm. Nó chạy trên chính engine tiện ích của WebKit — cái mà Safari dùng — và ở đâu Chrome có API mà WebKit không có (dấu trang, lịch sử, tải xuống, bảng bên, tài liệu ngoài màn hình, phông chữ, thông báo, giọng nói, đăng nhập OAuth), Search tự lấp đầy bằng code của chính mình. Chúng nằm sau nút hình mảnh ghép; ghim những cái hay dùng. Tự xây tiện ích riêng? Nạp thư mục của nó như một tiện ích unpacked và bấm Tải lại sau mỗi lần thay đổi, như trong chế độ nhà phát triển của Chrome. macOS 15.4 trở lên.
- **Tự cập nhật, lặng lẽ.** Mỗi ngày nó kiểm tra xem có bản dựng mới hơn không, tải về, xác minh chữ ký của Office Commun, và thay vào cho lần khởi động kế tiếp. Không thứ gì tự khởi động lại.

## Nó không làm gì

Cố ý vậy:

- Không có tiện ích nào bạn phải cài mới thấy dễ chịu. Chặn quảng cáo, ẩn thứ lộn xộn, chế độ đọc, picture-in-picture và mật khẩu đều có sẵn; tiện ích dành cho mọi thứ còn lại.
- Không đồng bộ, không tài khoản, không đám mây. Tab, lịch sử và mật khẩu của bạn nằm trên Mac và không ở nơi nào khác.
- Không đo lường, không phân tích, không báo cáo sự cố gửi đi đâu. Những thứ duy nhất rời khỏi Mac là các trang bạn yêu cầu, biểu tượng của chúng, và mỗi ngày một yêu cầu nhỏ để xem có bản mới hơn không.
- Một cửa sổ. Tab là kiểu "mới" duy nhất ở đây.

## Quyền riêng tư, cụ thể

| Thứ | Nơi nó nằm | Ai đọc được |
|---|---|---|
| Mật khẩu | Keychain đăng nhập macOS, dưới dạng các mục keychain thường được gắn nhãn `Search` | Search, bản được ký bởi Office Commun. Ứng dụng khác sẽ kích hoạt hộp thoại xin quyền của hệ thống. |
| Lịch sử, dấu trang, tab đang mở, phần tử bị ẩn | Các tệp JSON nhỏ trong `~/Library/Application Support/Search/` | Bạn. |
| Cookie và dữ liệu trang | Kystore riêng của WebKit dành cho ứng dụng | Các trang đã đặt chúng, như trong mọi trình duyệt. |
| Tiện ích | Unpack trong `~/Library/Application Support/Search/Extensions/`, dữ liệu nằm trong kho tiện ích của WebKit | Từng tiện ích, trong giới hạn các quyền bạn đã chấp nhận khi thêm nó. |
| Bất cứ thứ gì khác | Không nơi nào. Không có máy chủ nào. | — |

Tab **riêng tư** (`⇧⌘N`) có hộp cookie riêng và không để lại gì khi đóng.

## Bàn phím

| | |
|---|---|
| `⌘L` địa chỉ · `⌘K` chuyển tab · `⌘T` tab mới · `⌘W` đóng · `⇧⌘T` mở lại | `⌘[` `⌘]` quay lại, tới trước · `⇧⌘[` `⇧⌘]` tab trước, tab sau · `⌘1`–`⌘9` nhảy tới |
| `⇧⌘S` tab ngang trên cùng hay dọc bên trái · `⌘S` gập cột bên · `⇧⌘B` đánh dấu trang này | `⇧⌘R` chế độ đọc · `⇧⌘P` nổi video · `⇧⌘H` ẩn thứ gì đó · `⇧⌘U` thứ bị ẩn ở đây |
| `⌘F` tìm · `⌘D` nhân bản tab · `⇧⌘C` sao chép địa chỉ · `⇧⌘V` dán và đi | `⌘Y` lịch sử · `⇧⌘J` tải xuống · `⌘,` cài đặt · `⌥⌘L` mật khẩu |

`⌃Tab` và `⌃⇧Tab` lướt dọc hàng tab; `Tab` vẫn thuộc về trang, để di chuyển trong biểu mẫu. `esc` cất đi bất cứ thứ gì đang mở.

---

## Dành cho nhà phát triển

### Vì sao mã nguồn nằm ở đây

Để bất kỳ ai cũng có thể đọc chính xác những gì một trình duyệt đang giữ mật khẩu và lịch sử của họ làm, tự xây dựng nó, hoặc sửa thứ gì khiến họ khó chịu. Code đủ nhỏ để thực sự đọc được — khoảng 12.700 dòng Swift, không phụ thuộc gì ngoài thứ Apple đóng kèm macOS, mỗi file một việc.

### Cách dựng

- macOS 14 trở lên, Xcode 16 / Swift 6 toolchain
- `swift build` — chạy ứng dụng thẳng từ binary SwiftPM
- `./build.sh` — lắp một `Search.app` thật, bấm đúp được, vào thư mục `build/`, ký ad-hoc để chạy trên chính Mac của bạn

Bản dựng bạn tự làm sẽ không được notarize và không mang Developer ID của Office Commun, nên lần mở đầu cần chuột phải → Mở (hoặc cho phép trong System Settings → Privacy & Security). Đó là bình thường — cũng giống những gì xảy ra với bất kỳ ứng dụng nào không đến từ App Store hay một DMG đã notarize. Bản dựng của bạn cũng giữ mật khẩu riêng với bản Search đã ký: keychain phân biệt hai thứ bằng chữ ký của chúng.

`./build.sh release dmg` cũng tạo `Search.dmg` / `Search.zip`. `./build.sh release ship` còn notarize và staple — bước đó cần chứng chỉ Developer ID và thông tin xác thực Apple, nên thực chất chỉ có tác dụng với các bản phát hành của chính Office Commun.

### Nó được ghép lại thế nào

- **SwiftUI** cho mọi thứ được vẽ, **AppKit** cho một số ít chỗ SwiftUI không với tới trên macOS (thanh tiêu đề cửa sổ, kéo cửa sổ bằng khoảng trống của hàng tab), **WKWebView** cho các trang.
- Một `Tab` cho mỗi trang. Web view của nó được dựng lười — tab khôi phục từ phiên trước không tốn một tiến trình nào cho tới khi bạn chuyển sang nó. Đó là phần lớn lý do mở lên với hai mươi tab vẫn tức thì. Mỗi trang chạy trong tiến trình nội dung riêng của WebKit, như trong Safari; tab bạn đóng là biến mất thật.
- Trình chặn quảng cáo là một `WKContentRuleList` được biên dịch một lần lúc khởi động và được thực thi bên trong tầng mạng của WebKit, trước khi một yêu cầu được gửi — chi phí lúc chạy bằng không, khác với một trình chặn JavaScript.
- Các phần tử bị ẩn là danh sách selector theo từng trang, được tiêm vào như một stylesheet ngay khi tài liệu bắt đầu, nên không bao giờ có thứ gì bị thấy là lộ ra rồi biến mất.
- Mọi màu đều là một cặp sáng/tối trong `Design.swift`, phân giải theo giao diện của cửa sổ; phần code còn lại không biết mình đang ở chế độ nào.
- Tiện ích chạy trên `WKWebExtension` (macOS 15.4+). `Crx.swift` tải tiện ích từ địa chỉ cập nhật công khai của Chrome Web Store và đối chiếu chữ ký CRX3 với id của tiện ích trước khi bất cứ thứ gì được mở gói. `Extensions.swift` là phía trình duyệt của hiệp ước với WebKit — tab, cửa sổ, quyền, popup. `ExtensionShims.swift`, ngay lúc cài, thêm một script nhỏ vào worker, các trang và content script của tiện ích: nó định nghĩa các API mà Chrome có mà WebKit thiếu — `userScripts`, `privacy`, `browsingData`, `sessions`, FileSystem API cũ và vài thứ khác — dưới dạng các lời gọi được Search trả lời bằng code gốc, và hàn những chỗ WebKit xử lý khác Chrome: phản hồi từ trang không trả lời, listener được thêm sau khi worker khởi động, những worker WebKit mất dấu, các thành viên và hằng số bị bỏ sót. Trang tiện ích được phục vụ từ `chrome-extension://<id>/`, địa chỉ chúng có trong Chrome, để máy chủ và các trang nhận ra chúng. `./bench ext-*` điều khiển toàn bộ từ shell trên một bản chạy thử. `ExtensionNative.swift` nói native messaging của Chrome với các host được đăng ký trong thư mục `NativeMessagingHosts` của Chrome.
- `Sources/Search/` mỗi file một việc: `Vault.swift` là keychain, `Shield.swift` là trình chặn quảng cáo, `Curtain.swift` là các phần tử bị ẩn, `Session.swift` là thứ quay lại lúc khởi động, `Updater.swift` là cập nhật, `Bench.swift` là socket thử nghiệm, v.v. Không có framework riêng nào phải học trước.

### Thử nghiệm mà không cần đóng nó

Bật **Settings › General › Let a script drive Search**, và ứng dụng đang chạy sẽ nghe trên một Unix socket trong chính thư mục của nó (chỉ user của bạn đọc được). `./bench` ở gốc repository nói chuyện được với nó:

```
./bench open https://example.com     # một tab riêng, ở cuối hàng tab của bạn, đánh dấu bằng biểu tượng ống nghiệm
./bench wait 2e7e7e89                 # đợi tới khi nó tải xong
./bench text 2e7e7e89                 # văn bản của trang
./bench shot 2e7e7e89 out.png         # ảnh chụp nó
./bench click 2e7e7e89 "button.go"    # nhấp, gõ, submit — qua chính sự kiện của trang
./bench probe                         # trạng thái cửa sổ: bảng đang mở, một modal, mọi cửa sổ
./bench close all
```

Tab bench không bao giờ được tự chọn cho bạn, không bao giờ vào phiên hay lịch sử, và biến mất khi script bảo vậy. Đó là cách trình duyệt này được thử nghiệm trong khi có người đang dùng nó.

### Đóng góp

Issues và pull request được hoan nghênh thực sự — xem [CONTRIBUTING.md](CONTRIBUTING.md) để biết chúng được đánh giá như thế nào và cái gì thường được gộp. Tóm lại: thay đổi nhỏ, không thêm phụ thuộc, không thứ nào gọi về máy chủ. Phát hiện vấn đề bảo mật? Hãy báo riêng tư, như [SECURITY.md](SECURITY.md) hướng dẫn.

### Giấy phép

MIT — xem [LICENSE](LICENSE). Muốn làm gì với code cũng được. "Search" và biểu tượng ứng dụng thuộc về Office Commun; vui lòng đổi tên một fork trước khi phân phối nó dưới tên khác.
