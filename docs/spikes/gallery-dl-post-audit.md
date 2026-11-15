# gallery-dl POST audit (gallery-dl 1.32.19)

Every POST request the bundled gallery-dl's site extractors can make, read in the source and classified, so the
egress guard (`Engines/bridge/egress_guard.py`, D-72) can allow the reads sites need and nothing else.

- **Read**: listings, searches, metadata and file links. **Token**: an anonymous or public-client token used only to read.
- **Consent**: an age gate that sets a cookie. Allowed only where it cannot be stored on a signed-in account.
- **Login** and **state change** (favourites, watching, likes, rating settings, quota resets) are always blocked.
  MediaPull never configures site usernames or passwords, so login code paths are not reached in normal use.
- No extractor uses PUT, PATCH or DELETE, and no GraphQL document in gallery-dl is a mutation.
- One GET acts on an account (vipergirls `post_thanks.php?do=post_thanks_add`, only with the `like` option); the guard refuses it too.

| Site module | Line | Endpoint | Kind | Guard |
|---|---|---|---|---|
| 500px | 124 | `/graphql` | read | Allowed |
| artstation | 157 | `/api/v2/search/projects.json` | read | Allowed |
| audiochan | 105 | `/audios/{id}/play-intent` | read | Allowed |
| audiochan | 108 | `/audios/{id}/stream-url` | read | Allowed |
| behance | 78 | `/v3/graphql` | read | Allowed |
| blogger | 117 | `/_/BloggerVideoPlayerUi/data/batchexecute?rpcids=WcwnYd&source-path=/v` | read | Allowed |
| bunkr | 198 | `/api/_001_v2` | read | Allowed |
| civitai | 1048 | `/multi-search` | read | Allowed |
| cosmos | 47 | `/graphql?q={operationName}` | read | Allowed |
| cosplayrule34 | 132 | `/cms/load-more-photos.php` | read | Allowed |
| cyberfile | 26 | `/account/ajax/load_files, /account/ajax/file_details` | read | Allowed |
| cyberfile | 41 | `/account/ajax/load_files (retry)` | read | Allowed |
| exhentai | 355 | `/api.php` | read | Allowed |
| exhentai | 413 | `/api.php` | read | Allowed |
| exhentai | 474 | `/api.php` | read | Allowed |
| exhentai | 662 | `/api.php` | read | Allowed |
| filester | 30 | `/v2/api/public/download` | read | Allowed |
| furaffinity | 326 | `/search/` | read | Allowed |
| furry34 | 90 | `/api/v2/post/search/root, /api/v2/post/search/playlist/{id}` | read | Allowed |
| imagehosts | 51 | `the image page URL itself` | read | Allowed |
| imgbb | 105 | `/json` | read | Allowed |
| instagram | 1278 | `/api/graphql` | read | Allowed |
| instagram | 1322 | `/api/v1/tags/{tag}/sections/` | read | Allowed |
| instagram | 1361 | `/graphql/query` | read | Allowed |
| joyreactor | 129 | `/graphql` | read | Allowed |
| kabeuchi | 67 | `/get_posts.php` | read | Allowed |
| kagane | 82 | `/api/v2/books/{chapter_id}` | read | Allowed |
| lexica | 58 | `/api/infinite-prompts` | read | Allowed |
| lofter | 131 | `/v2.0/blogHomePage.api?product=..., /oldapi/post/detail.api` | read | Allowed |
| luscious | 30 | `/graphql/nobatch/?operationName={op}` | read | Allowed |
| mangapark | 66 | `/apo/` | read | Allowed |
| misskey | 274 | `/api/users/show, /api/users/notes, /api/users/following, /api/notes/sh` | read | Allowed |
| plurk | 80 | `/Responses/get` | read | Allowed |
| plurk | 117 | `/TimeLine/getPlurks` | read | Allowed |
| poipiku | 189 | `/f/ShowIllustDetailF.jsp` | read | Allowed |
| poipiku | 202 | `/f/ShowAppendFileF.jsp` | read | Allowed |
| pornhub | 40 | `/{user}/{photos/gifs}[/sub]/ajax?page=N` | read | Allowed |
| rule34vault | 72 | `/api/v2/post/search/root, /api/v2/post/search/playlist/{id}` | read | Allowed |
| rule34xyz | 112 | `/api/v2/post/search/root, /api/v2/post/search/playlist/{id}` | read | Allowed |
| schalenetwork | 155 | `/books/detail/{gid}/{gkey}?crt={crt}` | read | Allowed |
| scrolller | 108 | `/admin` | read | Allowed |
| skeb | 280 | `/1/indexes/*/queries` | read | Allowed |
| slickpic | 108 | `/xhr/photo/get/list` | read | Allowed |
| steamcommunity | 316 | `/{id/profiles}/{uid}/{type}/screenshots` | read | Allowed |
| steamgriddb | 132 | `/api/public/search/assets` | read | Allowed |
| sxypix | 33 | `/php/gall.php` | read | Allowed |
| uploadir | 42 | `form action from the file page (download)` | read | Allowed |
| vk | 109 | `/al_photos.php` | read | Allowed |
| yiffverse | 91 | `/api/v2/post/search/root, /api/v2/post/search/playlist/{id}` | read | Allowed |
| artstation | 179 | `/api/v2/csrf_protection/token.json` | token | Allowed |
| deviantart | 1578 | `/oauth2/token` | token | Allowed |
| gofile | 84 | `/accounts` | token | Allowed |
| inkbunny | 346 | `/api_login.php` | token | Allowed |
| kagane | 26 | `/api/integrity` | token | Allowed |
| reddit | 537 | `/api/v1/access_token` | token | Blocked |
| twitter | 1918 | `/1.1/guest/activate.json` | token | Allowed |
| weibo | 333 | `/visitor/genvisitor2` | token | Allowed |
| foolslide | 25 | `every chapter/manga page URL` | consent | Blocked |
| hentaifoundry | 212 | `/site/filters` | consent | Allowed |
| newgrounds | 205 | `/age-verification/ignore-filter` | consent | Blocked |
| szurubooru | 37 | `/.gatekeeper/cmd/accept18plusUnverified` | consent | Allowed |
| toyhouse | 124 | `/~account/warnings/accept` | consent | Blocked |
| webmshare | 76 | `/is_adult` | consent | Allowed |
| deviantart | 1528 | `/api/v1/oauth2/user/friends/watch/{username}` | state change | Blocked |
| deviantart | 1535 | `/api/v1/oauth2/user/friends/unwatch/{username}` | state change | Blocked |
| exhentai | 181 | `/gallerypopups.php?gid=..&t=..&act=addfav` | state change | Blocked |
| exhentai | 602 | `/home.php` | state change | Blocked |
| newgrounds | 589 | `/suitabilities` | state change | Blocked |
| schalenetwork | 175 | `/books/data/{gid}/{gkey}/{id}/{key}/{w}?crt=..&action=dl` | state change | Blocked |
| vipergirls | 134 | `/post_thanks.php?do=post_thanks_add&p={post}&securitytoken={hash}` | state change | Blocked |
| ao3 | 89 | `/users/login` | login | Blocked |
| aryion | 53 | `/forum/ucp.php?mode=login` | login | Blocked |
| bluesky | 570 | `/xrpc/com.atproto.server.createSession` | login | Blocked |
| bluesky | 570 | `/xrpc/com.atproto.server.refreshSession` | login | Blocked |
| chevereto | 76 | `same path as the protected album/user page` | login | Blocked |
| cyberfile | 37 | `/ajax/folder_password_process` | login | Blocked |
| deviantart | 148 | `/_sisu/do/step2` | login | Blocked |
| deviantart | 160 | `/_sisu/do/signin` | login | Blocked |
| deviantart | 1578 | `/oauth2/token` | login | Blocked |
| exhentai | 98 | `/index.php?act=Login&CODE=01` | login | Blocked |
| filester | 46 | `form action path from the password page` | login | Blocked |
| girlswithmuscle | 46 | `/login/` | login | Blocked |
| imgbb | 60 | `/login` | login | Blocked |
| inkbunny | 346 | `/api_login.php` | login | Blocked |
| iwara | 453 | `/user/login` | login | Blocked |
| iwara | 467 | `/user/token` | login | Blocked |
| kemono | 231 | `/api/v1/authentication/login` | login | Blocked |
| mangadex | 373 | `/realms/mangadex/protocol/openid-connect/token` | login | Blocked |
| mangadex | 401 | `/auth/login, /auth/refresh` | login | Blocked |
| mangoxo | 48 | `/api/login` | login | Blocked |
| newgrounds | 147 | `/login` | login | Blocked |
| newgrounds | 165 | `/login/two-factor` | login | Blocked |
| nijie | 147 | `/login_int.php` | login | Blocked |
| pawchive | 504 | `/account/login` | login | Blocked |
| pillowfort | 108 | `/users/sign_in` | login | Blocked |
| pixiv | 1209 | `/auth/token` | login | Blocked |
| poipiku | 113 | `/f/LoginUserF.jsp` | login | Blocked |
| reddit | 537 | `/api/v1/access_token` | login | Blocked |
| rule34xyz | 134 | `/api/v2/auth/signin` | login | Blocked |
| sankaku | 317 | `/auth/token` | login | Blocked |
| scrolller | 108 | `/api/v2/graphql` | login | Blocked |
| seiga | 76 | `form action from /login?site=seiga` | login | Blocked |
| seiga | 92 | `MFA form action` | login | Blocked |
| subscribestar | 137 | `/session.json` | login | Blocked |
| subscribestar | 143 | `/session/password.json` | login | Blocked |
| tapas | 59 | `/account/authenticate` | login | Blocked |
| vipergirls | 119 | `/login.php?do=login` | login | Blocked |
| xenforo | 209 | `/login/login` | login | Blocked |
| zerochan | 60 | `/login` | login | Blocked |
