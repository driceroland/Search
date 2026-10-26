import Foundation
import WebKit

// YouTube's ads, part of Shield.
//
// Shield's rule list can't stop them on its own: YouTube doesn't fetch its
// ads from someone else's server, it announces them in the player's own data
// (the page's ytInitialPlayerResponse, then each /youtubei/v1/player answer)
// and plays them from the same servers as the video. So on YouTube's own
// hosts, and only there, a small script in the page's world takes the ad
// schedule out of that data before the player reads it: the keys
// adPlacements, adSlots, playerAds and adBreakHeartbeatParams, at the top of
// an answer that looks like YouTube's (it has responseContext,
// playabilityStatus, streamingData or videoDetails), or of the playerResponse
// such an answer carries. Nothing else is touched; an answer of any other
// shape is handed on as it came, so a change at YouTube leaves the video
// playing, with its ads, rather than broken.
//
// Written for Search from YouTube's page structure as it is publicly
// documented; no code is taken from another blocker.
//
// What the page-world script can reach, for Security: only the page's own
// JSON.parse, Response.prototype.json and two window properties
// (ytInitialPlayerResponse, ytInitialData), all of which the page itself can
// already rewrite. It carries no handler, no message, no Search name or
// global, sends nothing anywhere and runs nothing it is given (no eval,
// no Function). A WKUserScript is injected by WebKit, so a page's CSP doesn't
// apply to it and needs no exception. Its source is visible through
// toString(), as LiveRate's and the passkeys patch are: never hidden.
//
// A second script, in Search's own world (pages can't see it), is the
// fallback when an ad plays all the same: while YouTube's player says
// `ad-showing`, the video is muted and played at 16×, and its sound and speed
// are put back the moment the ad is over. It never seeks: an ad stitched into
// the video itself would make a jump to "the end" the end of the video.
//
// Both go into a tab only while Shield is on and not paused for the site the
// tab is on (Settings' "Block on youtube.com" turns them off there), and each
// does nothing in a frame that isn't one of YouTube's hosts.

enum YouTubeAds {
    /// Where the scripts work. Exact hosts: accounts.youtube.com and the
    /// like are YouTube's but have no player.
    static let hosts = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
        "youtube-nocookie.com", "www.youtube-nocookie.com",
    ]

    /// The hosts for this run: test runs can add a local stand-in for
    /// YouTube (`test.youtubeHosts` in the test settings), so a fixture page
    /// can be checked without YouTube.
    static var hostsThisRun: [String] {
        guard Store.testing else { return hosts }
        return hosts + (Store.settings.stringArray(forKey: "test.youtubeHosts") ?? [])
    }

    /// The scripts for the next document of a tab on `site` (its main
    /// frame's host, without www): none while Shield is off or paused there.
    @MainActor
    static func scripts(for site: String?) -> [WKUserScript] {
        guard Shield.shared.enabled, !Shield.shared.isPaused(on: site) else { return [] }
        let hosts = hostsThisRun
        return [
            WKUserScript(source: page(hosts: hosts), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page),
            WKUserScript(source: skipper(hosts: hosts), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world),
        ]
    }

    static func hostList(_ hosts: [String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: hosts)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// In the page's own world, before any of its scripts.
    static func page(hosts: [String]) -> String {
        """
        (function () {
          'use strict';
          if (\(hostList(hosts)).indexOf(location.hostname) < 0) return;
          // Taken now, before the page runs: what the page puts in their
          // place later is never what this calls.
          var apply = Reflect.apply, owns = Object.prototype.hasOwnProperty,
              define = Object.defineProperty, isArray = Array.isArray;
          var ads = ['adPlacements', 'adSlots', 'playerAds', 'adBreakHeartbeatParams'];
          var marks = ['responseContext', 'playabilityStatus', 'streamingData', 'videoDetails'];
          function plain(o) { return o !== null && typeof o === 'object' && !isArray(o); }
          function youtubes(o) {
            for (var i = 0; i < marks.length; i++) if (apply(owns, o, [marks[i]])) return true;
            return false;
          }
          function strip(o) {
            if (!plain(o) || !youtubes(o)) return;
            for (var i = 0; i < ads.length; i++) if (apply(owns, o, [ads[i]])) delete o[ads[i]];
          }
          function one(o) {
            if (!plain(o)) return;
            strip(o);
            if (apply(owns, o, ['playerResponse'])) strip(o.playerResponse);
          }
          // Whatever happens in here, the page gets back what it asked for.
          function prune(value) {
            try {
              if (isArray(value)) {
                for (var i = 0; i < value.length && i < 8; i++) one(value[i]);
              } else {
                one(value);
              }
            } catch (e) {}
            return value;
          }
          try {
            var parse = JSON.parse;
            if (typeof parse === 'function') {
              define(JSON, 'parse', {
                value: ({ parse(text, reviver) { return prune(apply(parse, JSON, arguments)); } }).parse,
                writable: true, enumerable: false, configurable: true
              });
            }
          } catch (e) {}
          try {
            var json = typeof Response === 'function' && Response.prototype.json;
            var then = Promise.prototype.then;
            if (typeof json === 'function') {
              define(Response.prototype, 'json', {
                value: ({ json() { return apply(then, apply(json, this, []), [prune]); } }).json,
                writable: true, enumerable: true, configurable: true
              });
            }
          } catch (e) {}
          // The first page's data is a script's `var ytInitial… = {…}`: a
          // setter already there is what that assignment goes through.
          ['ytInitialPlayerResponse', 'ytInitialData'].forEach(function (name) {
            try {
              if (apply(owns, window, [name])) return;
              var held;
              define(window, name, {
                get: function () { return held; },
                set: function (value) { held = prune(value); },
                enumerable: true, configurable: true
              });
            } catch (e) {}
          });
        })();
        """
    }

    /// In Search's world: an ad that plays all the same goes by muted and
    /// fast, and the video comes back as it was.
    static func skipper(hosts: [String]) -> String {
        """
        (function () {
          'use strict';
          if (\(hostList(hosts)).indexOf(location.hostname) < 0) return;
          var held = new WeakMap();
          function look(event) {
            var video = event.target;
            if (!(video instanceof HTMLVideoElement)) return;
            var player = video.closest('.html5-video-player');
            var ad = !!player && player.classList.contains('ad-showing');
            var was = held.get(video);
            try {
              if (ad) {
                if (!was) {
                  was = { muted: video.muted, rate: video.playbackRate };
                  held.set(video, was);
                  video.muted = true;
                }
                if (video.playbackRate !== 16) video.playbackRate = 16;
              } else if (was) {
                held.delete(video);
                video.playbackRate = was.rate;
                video.muted = was.muted;
              }
            } catch (e) {}
          }
          ['playing', 'timeupdate', 'durationchange', 'emptied'].forEach(function (type) {
            document.addEventListener(type, look, true);
          });
        })();
        """
    }

    /// Shield's rules for YouTube: where its player reports ads and fetches
    /// them, never the video. Each path is anchored on YouTube's own hosts;
    /// Google's ad hosts that are third parties on YouTube are already in
    /// Shield's list (doubleclick.net, googlesyndication.com…).
    static let paths = [
        "/api/stats/ads", "/pagead/", "/ptracking", "/get_midroll_info",
        "/youtubei/v1/player/ad_break", "/pcs/activeview",
    ]

    static func filter(path: String) -> String {
        "^https?://([^/]+\\.)?youtube\\.com" + path.replacingOccurrences(of: ".", with: "\\.")
    }

    static var rules: [[String: Any]] {
        var rules: [[String: Any]] = paths.map { path in
            ["trigger": ["url-filter": filter(path: path)], "action": ["type": "block"]]
        }
        // The player's quality reports for an ad, never the video's own.
        rules.append([
            "trigger": ["url-filter": "^https?://([^/]+\\.)?youtube\\.com/api/stats/qoe\\?.*adformat="],
            "action": ["type": "block"],
        ])
        // Google's own ad paths and the video ads SDK, only from YouTube's
        // pages: other sites' players may need the SDK to play at all.
        let youtube = ["*youtube.com", "*youtube-nocookie.com"]
        for filter in ["^https?://([^/]+\\.)?google\\.com/pagead/", "^https?://imasdk\\.googleapis\\.com/"] {
            rules.append([
                "trigger": ["url-filter": filter, "if-domain": youtube],
                "action": ["type": "block"],
            ])
        }
        return rules
    }
}
