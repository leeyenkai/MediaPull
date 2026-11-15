# gallery-dl sites in MediaPull (gallery-dl 1.32.19)

Every site the bundled gallery-dl supports, run through MediaPull's bridge (list the first 3 items, no sign-in, no browser
session) on gallery-dl's own test address for each site, on 15 to 16 November 2026. Sites change daily; this is a snapshot.

- 415 site categories (each instance of a shared engine counts once); 372 had a test address and were run.
- **196 worked** with no sign-in at all. None was blocked by MediaPull's egress guard after D-72.
- 65 need a signed-in browser session, a browser check (Cloudflare) the browser pane passes, or an API key.
  Inside the app the browser's cookies and user agent go with the download, which is what signed-in sites need. Whether that
  passes a site's bot check was not shown: in the app test, Reddit, Unsplash, 500px and Weibo still refused after the page was opened.
- The rest were down, slow, rate-limited or pointed at test items that no longer exist (27 down, 22 slow, 44 errors or items gone, 15 nothing listed).
- 42 categories have no test address in gallery-dl and were not run: adultphotosets, animepictures, artfight, bakashots, batcave, cara, clonr, comicartfans, coomerfans, cosmos, cosplayrule34, dcinside, exhentai, febri, framedsc, ganknow, goonbox, harvardlawnuremberg, hdoujin, hentaifoundry, hentaihand, hentainexus, hitomi, imdb, imxtw, kagane, leftybooru, mangayi, mgrenders, myfigurecollection, nhentai, onlyhaven, pawchive, postype, sakuhentai, schalenetwork, shareimage, snapchat, sofurry, steamcommunity, vanlifetrader, whitekitten.

End to end through the app (open the page in the browser, download 3 items, convert, file into folders): Bluesky, Imgur,
ArtStation, Mastodon, Behance, VSCO, Wallhaven, Pinterest, TikTok photo posts, Itaku, WEBTOON, ImgBB, Catbox, Tenor, Patreon,
Lensdump, Postimages, Telegraph, SteamGridDB, VK and Civitai saved correctly. Twitter needs the browser signed in; Reddit refuses
download tools unless your own API key is set; Tumblr, DeviantArt and Flickr were rate-limited on gallery-dl's shared keys
(your own key avoids that); Pixiv needs its own app sign-in, which MediaPull does not set up yet.

| Site | Category | Sign-in | Result |
|---|---|---|---|
| 2ch | 2ch | none | Works |
| Futaba Channel | 2chan | none | Works |
| 35PHOTO | 35photo | none | Works |
| 4archive | 4archive | none | Needs sign-in, a browser check or a key |
| 4chan | 4chan | none | Test item gone |
| 4chanarchives | 4chanarchives | none | Needs sign-in, a browser check or a key |
| 4plebs | 4plebs | none | Needs sign-in, a browser check or a key |
| 500px | 500px | none | Needs sign-in, a browser check or a key |
| 8chan | 8chan | none | Site error or item gone |
| 8kun | 8kun | none | Works |
| 8muses | 8muses | none | Slow (over 100 s for 3 items) |
| 94chan | 94chan | none | Site down or unreachable |
| Acidimg | acidimg | none | Site down or unreachable |
| Adult Empire | adultempire | none | Works |
| AGNPH | agnph | none | Works |
| AHottie | ahottie | none | Slow (over 100 s for 3 items) |
| AIBooru | aibooru | optional | Works |
| All girl | allgirlbooru | none | Works |
| AllPornComic | allporncomic | none | Works |
| Reactor | anime.reactor | none | Nothing listed |
| Archive of Our Own | ao3 | optional | Slow (over 100 s for 3 items) |
| Arcalive | arcalive | none | Works |
| Architizer | architizer | none | Needs sign-in, a browser check or a key |
| Archived.Moe | archivedmoe | none | Needs sign-in, a browser check or a key |
| Archive of Sins | archiveofsins | none | Needs sign-in, a browser check or a key |
| Are.na | arena | none | Needs sign-in, a browser check or a key |
| ArtStation | artstation | none | Works |
| Eka's Portal | aryion | optional | Works |
| ATFBooru | atfbooru | optional | Site error or item gone |
| All The Fallen | atfforum | none | Works |
| Audiochan | audiochan | none | Needs sign-in, a browser check or a key |
| Azur Lane Wiki | azurlanewiki | none | Works |
| arch.b4k.dev | b4k | none | Works |
| baraag | baraag | oauth | Works |
| BBC | bbc | none | Works |
| Bbw-chan | bbw-chan | none | Test item gone |
| Bcbnsfw | bcbnsfw | none | Site error or item gone |
| Behance | behance | none | Works |
| Bellazon | bellazon | none | Works |
| Bilibili | bilibili | none | Test item gone |
| Bitly | bitly | none | Nothing listed |
| BlacktoWhite | blacktowhite | none | Test item gone |
| Blogspot | blogspot | none | Works |
| Bluesky | bluesky | optional | Works |
| Booruvar | booruvar | optional | Needs sign-in, a browser check or a key |
| Boosty | boosty | cookies | Works |
| BOOTH | booth | none | Works |
| Bulbapedia | bulbapedia | none | Needs sign-in, a browser check or a key |
| Bunkr | bunkr | none | Works |
| Catbox | catbox | none | Works |
| Cavemanon | cavemanon | none | Site down or unreachable |
| celebforum | celebforum | none | Site error or item gone |
| Chelseacrew | chelseacrew | none | Slow (over 100 s for 3 items) |
| Ci-en | cien | none | Works |
| Civitai | civitai | none | Works |
| Comedy Wildlife Photography Awards | comedywildlifephoto | none | Works |
| Comic Vine | comicvine | none | Needs sign-in, a browser check or a key |
| Coomer | coomer | optional | Works |
| Cyberdrop | cyberdrop | none | Test item gone |
| CyberFile | cyberfile | none | Works |
| Danbooru | danbooru | optional | Works |
| Dandadan | dandadan | none | Works |
| Danke fürs Lesen | dankefuerslesen | none | Works |
| Derpibooru | derpibooru | key | Works |
| Desuarchive | desuarchive | none | Works |
| DeviantArt | deviantart | oauth | Slow (over 100 s for 3 items) |
| Discord | discord | none | Needs sign-in, a browser check or a key |
| donotsta.re | donotsta.re | none | Works |
| Draw Friends | drawfriends | none | Test item gone |
| Dynasty Reader | dynastyscans | none | Works |
| e621 | e621 | optional | Works |
| e6AI | e6ai | optional | Site down or unreachable |
| e926 | e926 | optional | Works |
| Endchan | endchan | none | Works |
| EPORNER | eporner | none | Works |
| EroMe | erome | none | Works |
| EVERIA.CLUB | everia | none | Works |
| Facebook | facebook | cookies | Works |
| pixivFANBOX | fanbox | cookies | Works |
| Wikimedia | fandom-discogs | none | Works |
| Wikimedia | fandom-hearthstone | none | Works |
| Wikimedia | fandom-hildatheseries | none | Works |
| Wikimedia | fandom-mushishi | none | Works |
| Wikimedia | fandom-projectsekai | none | Works |
| Wikimedia | fandom-www | none | Test item gone |
| Wikimedia | fandom-youtube | none | Works |
| Fansly | fansly | none | Nothing listed |
| Fantia | fantia | cookies | Works |
| Fapachi | fapachi | none | Needs sign-in, a browser check or a key |
| Fapello | fapello | none | Works |
| Fappic.com | fappic | none | Nothing listed |
| Fashion Nova | fashionnova | none | Test item gone |
| FikFap | fikfap | none | Works |
| filester.me | filester | none | Works |
| Fireden | fireden | none | Works |
| FitNakedGirls | fitnakedgirls | none | Works |
| Flickr | flickr | oauth | Works |
| foriio | foriio | none | Needs sign-in, a browser check or a key |
| freeradical.zone | freeradical.zone | none | Works |
| Fur Affinity | furaffinity | cookies | Needs sign-in, a browser check or a key |
| Furbooru | furbooru | key | Works |
| Furry 34 com | furry34 | none | Works |
| Gelbooru | gelbooru | none | Needs sign-in, a browser check or a key |
| Girlsreleased | girlsreleased | none | Slow (over 100 s for 3 items) |
| Girls with Muscle | girlswithmuscle | optional | Works |
| Gofile | gofile | none | Site error or item gone |
| Gurochan | gurochan | none | Slow (over 100 s for 3 items) |
| HatenaBlog | hatenablog | none | Works |
| Hentai2Read | hentai2read | none | Works |
| Hentai Cosplay | hentaicosplay | none | Works |
| HentaiEnvy | hentaienvy | none | Site down or unreachable |
| HentaiEra | hentaiera | none | Works |
| HentaiFox | hentaifox | none | Works |
| HentaiHere | hentaihere | none | Works |
| Hentai Image | hentaiimg | none | Site error or item gone |
| HentaiRox | hentairox | none | Site down or unreachable |
| HentaiZap | hentaizap | none | Site down or unreachable |
| HiperDEX | hiperdex | none | Test item gone |
| horne | horne | required | Needs sign-in, a browser check or a key |
| Hotleak | hotleak | none | Works |
| Hypnohub | hypnohub | none | Works |
| Idol Complex | idolcomplex | optional | Works |
| Illusion Game Cards | illusioncardsbooru | none | Needs sign-in, a browser check or a key |
| ImageBam | imagebam | none | Site error or item gone |
| ImageChest | imagechest | none | Works |
| ImageFap | imagefap | none | Works |
| ImagePond | imagepond | none | Works |
| ImageShack | imageshack | none | Works |
| ImageTwist | imagetwist | none | Site error or item gone |
| Imagevenue | imagevenue | none | Site error or item gone |
| ImgAdult | imgadult | none | Nothing listed |
| ImgBB | imgbb | optional | Works |
| imgbox | imgbox | none | Works |
| Imgclick | imgclick | none | Site down or unreachable |
| ImgDrive.net | imgdrive | none | Site down or unreachable |
| Nude Celeb | imglike | none | Test item gone |
| imgpile | imgpile | none | Test item gone |
| IMGPV | imgpv | none | Works |
| Imgspice | imgspice | none | Slow (over 100 s for 3 items) |
| ImgTaxi.com | imgtaxi | none | Site error or item gone |
| imgth | imgth | none | Site down or unreachable |
| imgur | imgur | none | Works |
| ImgWallet.com | imgwallet | none | Site down or unreachable |
| IMHentai | imhentai | none | Works |
| IMX.to | imxto | none | Site error or item gone |
| Inkbunny | inkbunny | optional | Works |
| Instagram | instagram | cookies | Site error or item gone |
| Issuu | issuu | none | Works |
| Itaku | itaku | none | Works |
| Iwara | iwara | optional | Works |
| JoyReactor | joyreactor | none | Site error or item gone |
| JPG Fish | jpgfish | none | Needs sign-in, a browser check or a key |
| かべうち | kabeuchi | none | Site error or item gone |
| KaliScan | kaliscan | none | Site down or unreachable |
| Keenspot | keenspot | none | Needs sign-in, a browser check or a key |
| Kemono | kemono | optional | Works |
| Khinsider | khinsider | none | Needs sign-in, a browser check or a key |
| Kohlchan | kohlchan | none | Works |
| Komikcast | komikcast | none | Site down or unreachable |
| Konachan | konachan | none | Needs sign-in, a browser check or a key |
| Koofr | koofr | none | Works |
| labyrinth.zone | labyrinth.zone | none | Works |
| Leak Gallery | leakgallery | none | Needs sign-in, a browser check or a key |
| Lensdump | lensdump | none | Works |
| Lexica | lexica | none | Slow (over 100 s for 3 items) |
| Lightbrd | lightbrd | none | Needs sign-in, a browser check or a key |
| Lightroom | lightroom | none | Works |
| Listal | listal | none | Works |
| livedoor Blog | livedoor | none | Works |
| LOFTER | lofter | none | Works |
| Lolibooru | lolibooru | none | Site down or unreachable |
| Loungeunderwear | loungeunderwear | none | Slow (over 100 s for 3 items) |
| Luscious | luscious | none | Needs sign-in, a browser check or a key |
| Madokami | madokami | required | Needs sign-in, a browser check or a key |
| manebooru.art | manebooru.art | none | Works |
| MangaDex | mangadex | optional | Works |
| MangaFire | mangafire | none | Test item gone |
| Manga Fox | mangafox | none | Works |
| MangaFreak | mangafreak | none | Works |
| Manga Here | mangahere | none | Site error or item gone |
| MangaKakalot | mangakakalot | none | Needs sign-in, a browser check or a key |
| MangaNato | manganato | none | Needs sign-in, a browser check or a key |
| MangaPark | mangapark | none | Needs sign-in, a browser check or a key |
| MangaRead | mangaread | none | Needs sign-in, a browser check or a key |
| MangaReader | mangareader | none | Site down or unreachable |
| MangaTaro | mangataro | none | Works |
| MangaTown | mangatown | none | Works |
| Mangoxo | mangoxo | optional | Slow (over 100 s for 3 items) |
| Super Mario Wiki | mariowiki | none | Works |
| mastodon.social | mastodon.social | oauth | Works |
| MediaWiki | mediawiki | none | Works |
| Monster Girl Encyclopedia Wiki | mgewiki | none | Needs sign-in, a browser check or a key |
| Michaelscameras | michaelscameras | none | Test item gone |
| Misskey.art | misskey.art | none | Works |
| Misskey.design | misskey.design | none | Works |
| Misskey.io | misskey.io | none | Works |
| MixDrop | mixdrop | none | Works |
| Modcloth | modcloth | none | Slow (over 100 s for 3 items) |
| Motherless | motherless | none | Site down or unreachable |
| My Hentai Gallery | myhentaigallery | none | Works |
| Adobe Portfolio | myportfolio | none | Works |
| MangaNato | natomanga | none | Needs sign-in, a browser check or a key |
| Naver Blog | naver-blog | none | Works |
| CHZZK | naver-chzzk | none | Needs sign-in, a browser check or a key |
| Naver Webtoon | naver-webtoon | none | Works |
| MangaNelo | nelomanga | none | Needs sign-in, a browser check or a key |
| Newgrounds | newgrounds | optional | Browser check or rate limit |
| nijie | nijie | required | Needs sign-in, a browser check or a key |
| Nitter.net | nitter.net | none | Nothing listed |
| Nitter.space | nitter.space | none | Needs sign-in, a browser check or a key |
| Nitter.tiekoetter | nitter.tiekoetter | none | Site down or unreachable |
| Nozomi.la | nozomi | none | Works |
| GaryC Booru | nozrip | none | Needs sign-in, a browser check or a key |
| NSFWalbum.com | nsfwalbum | none | Works |
| NudoStar.TV | nudostar | none | Works |
| NudoStar Forums | nudostarforum | optional | Test item gone |
| Oh Polly | ohpolly | none | Slow (over 100 s for 3 items) |
| OK.PORN | okporn | none | Works |
| Omg Miami Swimwear | omgmiamiswimwear | none | Site down or unreachable |
| Rule 34 | paheal | none | Works |
| Palanq | palanq | none | Works |
| Patreon | patreon | cookies | Works |
| Pawoo | pawoo | oauth | Needs sign-in, a browser check or a key |
| Pexels | pexels | none | Site down or unreachable |
| pholder | pholder | none | Needs sign-in, a browser check or a key |
| PhotoVogue | photovogue | none | Site down or unreachable |
| Picarto | picarto | none | Works |
| Picazor | picazor | none | Works |
| PicState | picstate | none | Works |
| Pictoa | pictoa | none | Works |
| Piczel | piczel | none | Works |
| PidgiWiki | pidgiwiki | none | Works |
| Pillowfort | pillowfort | optional | Works |
| Pinterest | pinterest | cookies | Works |
| Pinupgirlclothing | pinupgirlclothing | none | Slow (over 100 s for 3 items) |
| pixeldrain | pixeldrain | none | Test item gone |
| PiXhost | pixhost | none | Works |
| [pixiv] | pixiv | oauth | Needs sign-in, a browser check or a key |
| [pixiv] Novels | pixiv-novel | oauth | Needs sign-in, a browser check or a key |
| Pixnet | pixnet | none | Site down or unreachable |
| Plurk | plurk | none | Nothing listed |
| Poipiku | poipiku | cookies | Works |
| ponerpics.org | ponerpics.org | none | Needs sign-in, a browser check or a key |
| Ponybooru | ponybooru | key | Works |
| Poringa | poringa | none | Site error or item gone |
| Pornhub | pornhub | none | Works |
| Porn Image | pornimage | none | Nothing listed |
| PornPics.com | pornpics | none | Works |
| PornReactor | pornreactor | none | Nothing listed |
| PORNSTARS.TUBE | pornstarstube | none | Works |
| Postimages | postimg | none | Works |
| Putmega | putmega | none | Needs sign-in, a browser check or a key |
| Raddle | raddle | none | Needs sign-in, a browser check or a key |
| Raidlondon | raidlondon | none | Slow (over 100 s for 3 items) |
| Rawkuma | rawkuma | none | Works |
| RebeccaBlackTech | rbt | none | Works |
| Reactor | reactor | none | Nothing listed |
| Realbooru | realbooru | none | Works |
| Reddit | reddit | oauth | Browser check or rate limit |
| RedGIFs | redgifs | none | Works |
| Rule 34 | rule34 | none | Needs sign-in, a browser check or a key |
| Rule34Hentai | rule34hentai | none | Needs sign-in, a browser check or a key |
| Rule 34 | rule34us | none | Works |
| R34 Vault | rule34vault | none | Works |
| Rule 34 World | rule34world | optional | Works |
| Rule 34 XYZ | rule34xyz | optional | Works |
| S3ND | s3ndpics | none | Works |
| Safebooru | safebooru | none | Works |
| Sakugabooru | sakugabooru | none | Works |
| Sankaku Channel | sankaku | optional | Test item gone |
| Sankaku Complex | sankakucomplex | none | Works |
| Scatbooru | scatbooru | none | Works |
| Schan | schan | none | Site error or item gone |
| Scrolller | scrolller | optional | Works |
| Niconico Seiga | seiga | optional | Needs sign-in, a browser check or a key |
| Sen Manga | senmanga | none | Nothing listed |
| Sex.com | sexcom | none | Works |
| SilverPic.com | silverpic | none | Site down or unreachable |
| SimpCity Forums | simpcity | optional | Needs sign-in, a browser check or a key |
| Simply Hentai | simplyhentai | none | Works |
| Size Booru | sizebooru | none | Works |
| Skeb | skeb | none | Works |
| SlickPic | slickpic | none | Needs sign-in, a browser check or a key |
| SlideShare | slideshare | none | Site error or item gone |
| Smugloli | smugloli | none | Test item gone |
| SmugMug | smugmug | oauth | Site error or item gone |
| Snootbooru | snootbooru | none | Works |
| Social Media Girls Forums | socialmediagirlsforum | none | Needs sign-in, a browser check or a key |
| Soundgasm | soundgasm | none | Works |
| Speaker Deck | speakerdeck | none | Nothing listed |
| SteamGridDB | steamgriddb | none | Works |
| Sturdychan | sturdychan | none | Needs sign-in, a browser check or a key |
| SubscribeStar | subscribestar | optional | Works |
| Sushi.ski | sushi.ski | none | Test item gone |
| Sxypix | sxypix | none | Works |
| Tapas | tapas | optional | Test item gone |
| The Big ImageBoard | tbib | none | Works |
| TCB Scans | tcbscans | none | Works |
| Twitter t.co | tco | none | Works |
| Telegraph | telegraph | none | Works |
| Tenor | tenor | none | Works |
| The /b/ Archive | thebarchive | none | Needs sign-in, a browser check or a key |
| The /co/llection | thecollection | none | Works |
| The /co/llection | thecollectionS | none | Needs sign-in, a browser check or a key |
| TheFap | thefap | none | Works |
| The Hentai World | thehentaiworld | none | Works |
| TikTok | tiktok | cookies | Works |
| Tits In Tops Forum | titsintops | none | Needs sign-in, a browser check or a key |
| TMOHentai | tmohentai | none | Site down or unreachable |
| Toyhouse | toyhouse | none | Needs sign-in, a browser check or a key |
| Tumblr | tumblr | oauth | Browser check or rate limit |
| TumblrGallery | tumblrgallery | none | Site down or unreachable |
| Tungsten | tungsten | none | Needs sign-in, a browser check or a key |
| turbo.cr | turbo | none | Works |
| TurboImageHost.com | turboimagehost | none | Needs sign-in, a browser check or a key |
| Twibooru | twibooru | none | Works |
| Twitter | twitter | cookies | Needs sign-in, a browser check or a key |
| udongein.xyz | udongein.xyz | none | Works |
| Unique-vintage | unique-vintage | none | Slow (over 100 s for 3 items) |
| Unsplash | unsplash | none | Needs sign-in, a browser check or a key |
| Uploadir | uploadir | none | Site down or unreachable |
| Urlgalleries | urlgalleries | none | Needs sign-in, a browser check or a key |
| もえぴりあ | vanillarock | none | Works |
| Vidya Booru | vidyapics | none | Needs sign-in, a browser check or a key |
| /v/idyart2 | vidyart2 | none | Works |
| Vipergirls | vipergirls | optional | Slow (over 100 s for 3 items) |
| Vipr.im | vipr | none | Works |
| VISUABUSTERS | visuabusters | none | Works |
| VK | vk | none | Works |
| VSCO | vsco | none | Works |
| Wallhaven | wallhaven | key | Works |
| Wallpaper Cave | wallpapercave | none | Works |
| wanderingwires.net | wanderingwires.net | none | Slow (over 100 s for 3 items) |
| Warosu | warosu | none | Works |
| Weasyl | weasyl | key | Needs sign-in, a browser check or a key |
| webmshare | webmshare | none | Works |
| WEBTOON | webtoons | none | Works |
| Weeb Central | weebcentral | none | Works |
| Weibo | weibo | none | Needs sign-in, a browser check or a key |
| Whyp | whyp | none | Works |
| WikiArt.org | wikiart | none | Works |
| Wikimedia | wikibooks | none | Nothing listed |
| Wikimedia | wikidata | none | Site down or unreachable |
| Wikifeet | wikifeet | none | Works |
| Wikifeetx | wikifeetx | none | Works |
| Wikimedia | wikigg-hearthstone | none | Works |
| Wikimedia | wikigg-terraria | none | Works |
| Wikimedia | wikigg-www | none | Site error or item gone |
| Wikimedia Commons | wikimediacommons | none | Works |
| Wikimedia | wikinews | none | Nothing listed |
| Wikimedia | wikipedia | none | Works |
| Wikimedia | wikiquote | none | Site error or item gone |
| Wikimedia | wikisource | none | Nothing listed |
| Wikispecies | wikispecies | none | Slow (over 100 s for 3 items) |
| Wikimedia | wikiversity | none | Slow (over 100 s for 3 items) |
| Wikimedia | wikivoyage | none | Slow (over 100 s for 3 items) |
| Wikimedia | wiktionary | none | Works |
| Windsorstore | windsorstore | none | Slow (over 100 s for 3 items) |
| woem.space | woem.space | none | Works |
| www.julianbunker.com | www.julianbunker.com | none | Site error or item gone |
| www.kefblog.com.ng | www.kefblog.com.ng | none | Site error or item gone |
| Xasiat | xasiat | none | Works |
| Xbooru | xbooru | none | Works |
| Xcancel | xcancel | none | Site down or unreachable |
| Xfolio | xfolio | none | Site error or item gone |
| xHamster | xhamster | none | Works |
| XVideos | xvideos | none | Site error or item gone |
| yande.re | yandere | none | Works |
| Yiff verse | yiffverse | none | Works |
| YourLesbians | yourlesbians | none | Works |
| ytdl-generic | ytdl-generic | none | Needs sign-in, a browser check or a key |
| Zerochan | zerochan | optional | Works |
