#!/usr/bin/env python3
"""Check menu commands and Settings in a built Search.app with macOS app-language overrides."""
import time

import split_view as sv


def check(language, tabs, back, bookmarks, new_tab, page):
    sv.use("interface-" + language.lower())
    sv.setup()
    try:
        sv.launch(args=("-AppleLanguages", f"({language})"))
        menus = sv.cmd({"do": "menus"})["menus"]
        assert back in menus[tabs], (language, menus)
        assert any(new_tab in items for items in menus.values()), (language, menus)
        assert bookmarks in menus, (language, menus)
        sv.cmd({"do": "menu"})  # AppKit must still find SwiftUI's Bookmarks menu.
        for section in ("privacy", "themes"):
            sv.cmd({"do": "ui", "show": f"search://settings/{section}"})
            for _ in range(40):
                if sv.cmd({"do": "settings", "find": page})["settingsPage"] == section:
                    break
                time.sleep(0.1)
            else:
                raise AssertionError(f"{language}: search://settings/{section}")
        matches = sv.cmd({"do": "settings", "find": page})["found"]
        assert any(item["page"] == "privacy" for item in matches), (language, matches)
        for words, setting in (("Prevent cross-site tracking", "sites.keep"), ("Sec-GPC: 1", "privacy.gpc"),
                               ("Home background", "home.theme")):
            matches = sv.cmd({"do": "settings", "find": words})["found"]
            assert any(item["id"] == setting for item in matches), (language, matches)
        for words, setting in (("防止跨網站追蹤", "sites.keep"), ("將 Search 設為", "general.default"),
                               ("首頁背景", "home.theme")):
            matches = sv.cmd({"do": "settings", "find": words})["found"]
            assert any(item["id"] == setting for item in matches) == language.startswith("zh"), (language, matches)
    finally:
        sv.finish()
    print(language, "OK")


if __name__ == "__main__":
    check("zh-Hant-TW", "分頁", "上一頁", "書籤", "新增分頁", "隱私權")
    for language in ("en", "fr"):
        check(language, "Tabs", "Back", "Bookmarks", "New Tab", "Privacy")
