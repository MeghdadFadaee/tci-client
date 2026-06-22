# TCI Internet Portal HTTP API

This document describes the HTTP workflow used by the TCI Internet customer portal. It is written as implementation-independent API documentation so it can be used to build clients in any language.

The portal is not a JSON REST API. It is a session-based web application that returns HTML pages, uses HTTP cookies for authentication state, and requires solving an image captcha during login.

## Base URL

```text
https://internet.tci.ir
```

All relative URLs discovered in HTML responses should be resolved against this base URL.

## Session Model

The portal uses standard HTTP cookies.

Clients must:

1. Store cookies from every response.
2. Send stored cookies with every later request.
3. Persist cookies if long-lived sessions are desired.
4. Re-login when the stored session is expired or invalid.

A practical way to detect an authenticated session is to request `GET /panel` and check whether the returned HTML contains a logout marker such as:

```text
logout
خروج
```

If neither marker is present, treat the session as unauthenticated.

## Common Headers

The portal works with ordinary browser-like HTTP requests. At minimum, clients should support compressed responses and redirects.

Recommended request behavior:

```text
Accept-Encoding: gzip, deflate, br
```

Clients should:

- Follow redirects for login requests.
- Preserve cookies across redirects.
- Decode compressed responses.
- Submit form data as `application/x-www-form-urlencoded`.

## Authentication Flow

### 1. Fetch Login Page

```http
GET /panel HTTP/1.1
Host: internet.tci.ir
```

Purpose:

- Starts or resumes a portal session.
- Returns either the authenticated panel HTML or the login page HTML.
- Sets initial cookies needed for captcha and login.

If the response already contains an authenticated marker such as `logout` or `خروج`, the client can skip the login flow.

If the response is a login page, parse the HTML for:

- The login form `action` URL.
- The captcha image URL.

The captcha image is inside an image element with:

```html
id="loginCaptchaImage"
```

The form action and captcha image source may be absolute or relative URLs. Resolve relative values against `https://internet.tci.ir`.

### 2. Download Captcha Image

```http
GET {captcha_url} HTTP/1.1
Host: internet.tci.ir
Cookie: ...
```

Purpose:

- Downloads the captcha image associated with the current cookie session.

The response body is image data, typically suitable to save or display as a JPEG image. The captcha value must be solved by a user or by a separate OCR/captcha-solving process.

Important:

- Use the same cookie jar/session used for `GET /panel`.
- Do not fetch the captcha with a different session; the submitted captcha must match the session that received the image.

### 3. Submit Login Form

```http
POST {login_action_url} HTTP/1.1
Host: internet.tci.ir
Content-Type: application/x-www-form-urlencoded
Cookie: ...

username={username}&password={password}&captcha={captcha}&redirect=&LoginFromWeb=1
```

Form fields:

| Field | Required | Description |
| --- | --- | --- |
| `username` | Yes | TCI portal username. |
| `password` | Yes | TCI portal password. |
| `captcha` | Yes | Text from the captcha image downloaded in the same session. |
| `redirect` | Yes | Usually submitted as an empty string. |
| `LoginFromWeb` | Yes | Web login flag. Known working value: `1`. Some portal responses may also accept an empty value. |

Clients should URL-encode all form values.

Expected result:

- On success, the response or the redirected page contains an authenticated marker such as `logout` or `خروج`.
- On failure, the response remains on or returns to the login page.

After successful login, save the cookies returned by the login response. These cookies authenticate later requests.

## Authenticated Panel

### Fetch Panel

```http
GET /panel HTTP/1.1
Host: internet.tci.ir
Cookie: ...
```

Purpose:

- Returns the authenticated user dashboard as HTML.
- Contains account and service information, including reserved traffic.

There is no known structured JSON response for this data in the observed workflow. Clients must parse the returned HTML.

## Reserved Traffic Extraction

The reserved traffic value can be extracted from the authenticated `/panel` HTML.

Known Persian label:

```text
میزان ترافیک رزرو شما
```

Observed extraction strategy:

1. Search the HTML for an `h5` element containing `میزان ترافیک رزرو شما`.
2. Strip HTML tags.
3. Normalize whitespace.
4. Convert Persian digits to ASCII digits.
5. Normalize units:
   - `گیگابایت` to `GB`
   - `مگابایت` to `MB`
6. Read the final numeric value and unit.

Example normalized output:

```text
12.5 GB
```

Because the portal returns HTML, clients should treat this parser as fragile and keep it isolated so it can be updated if the page layout changes.

## Cookie Persistence Format

Cookie storage is client-specific. A portable representation is a map of cookie names to cookie values for the `internet.tci.ir` domain:

```json
{
  "cookie_name": "cookie_value"
}
```

When restoring persisted cookies, send them to:

```text
Domain: internet.tci.ir
Path: /
Secure: false or as originally received
Expires: session or original expiry
```

For best compatibility, preserve all cookie attributes if your HTTP library exposes them.

## Error Handling

Recommended client behavior:

- If `GET /panel` fails with a network or TLS error, report the request failure.
- If the login page does not contain a form action, treat the portal HTML as changed.
- If the login page does not contain `#loginCaptchaImage`, treat the portal HTML as changed.
- If captcha download fails, restart the login flow from `GET /panel`.
- If login POST does not return an authenticated marker, ask for a new captcha or verify credentials.
- If an authenticated request returns a login page, clear or refresh cookies and login again.

## Minimal Client Algorithm

```text
1. Create an HTTP client with cookie storage.
2. Load previously saved cookies, if available.
3. GET https://internet.tci.ir/panel.
4. If response contains "logout" or "خروج":
   - Session is valid.
   - Continue to panel parsing.
5. Otherwise:
   - Parse login form action.
   - Parse captcha image URL from #loginCaptchaImage.
   - GET captcha image using the same cookies.
   - Solve captcha.
   - POST credentials, captcha, redirect="", LoginFromWeb=1 to the form action.
   - Verify authenticated marker in the response.
   - Save cookies.
6. GET https://internet.tci.ir/panel.
7. Parse required dashboard values from HTML.
```

## Example cURL Flow

```bash
BASE_URL="https://internet.tci.ir"
COOKIE_JAR="./cookies.txt"

# 1. Fetch login page or authenticated panel.
curl -fsSL --compressed -L \
  -b "$COOKIE_JAR" \
  -c "$COOKIE_JAR" \
  "$BASE_URL/panel" \
  -o login.html

# 2. Parse login form action and captcha URL from login.html.
#    The exact parser is implementation-specific.

# 3. Download captcha with the same cookies.
curl -fsSL --compressed -L \
  -b "$COOKIE_JAR" \
  -c "$COOKIE_JAR" \
  "$CAPTCHA_URL" \
  -o captcha.jpg

# 4. Submit login.
curl -fsSL --compressed -L \
  -b "$COOKIE_JAR" \
  -c "$COOKIE_JAR" \
  --data-urlencode "username=$TCI_USERNAME" \
  --data-urlencode "password=$TCI_PASSWORD" \
  --data-urlencode "captcha=$CAPTCHA_TEXT" \
  --data-urlencode "redirect=" \
  --data-urlencode "LoginFromWeb=1" \
  "$LOGIN_ACTION_URL" \
  -o panel.html

# 5. Fetch authenticated panel again if needed.
curl -fsSL --compressed -L \
  -b "$COOKIE_JAR" \
  -c "$COOKIE_JAR" \
  "$BASE_URL/panel" \
  -o panel.html
```

## Security Notes

- Store usernames, passwords, and cookies securely.
- Treat cookies as credentials.
- Do not log passwords, captcha text, or full cookie values.
- Use HTTPS only.
- Do not share persisted session cookies between users.

## Known Limitations

- The portal uses HTML pages rather than stable JSON endpoints.
- Captcha is mandatory in the observed login flow.
- Page structure and Persian labels may change without versioning. (But nothing has changed over the past decade.)
- The reserved traffic parser depends on current dashboard markup.
