# Split View: Design Notes

## Agreed behavior

- A switch in Settings › Tabs enables split view. It starts off.
- A tab's context menu has a **Split Tab** action. Double-click keeps its current behavior.
- Choosing **Split Tab** shows that tab on the right and an empty pane on the left. Dragging another open tab into the left pane completes the split.
- The two pages remain separate tabs in the tab row or sidebar.
- The first version shows two pages side by side. The split starts at 50/50, and the divider can be dragged.
- Unsplit keeps both tabs open. The tab used last fills the window.
- Clicking a pane focuses its tab. Browser commands such as Back, ⌘L, ⌘F, and ⌘W act on that tab. The focused pane is visible as such.
- Selecting a third tab shows it alone. The split pair stays linked; selecting either member brings back the split view.
- Closing either member ends the split, and the other member fills the window.
- Both members have a small shared mark in the top tab row and sidebar. The focused member is distinct.
- Search restores normal split pairs and their divider positions after a restart.
- A split pair belongs to one Space. Switching away and back keeps it.
- A private tab may share a split with a normal tab during the current run. Private tab details stay out of saved session data.
- The context menu of either member has an **Unsplit** action.
- Clicking an empty pane lets a person choose an open tab, including with the keyboard. Escape cancels a pending split.
- A new foreground tab fills the window while the pair stays linked. Opening a background tab leaves the split visible.
- One Space may hold several split pairs. A tab belongs to at most one pair.
- While a pair is visible, another tab's context menu can replace the left or right pane. The replaced tab stays open as a single tab.
- Pinned tabs may join a split. If ⌘W rests a pinned member, the split ends and the other member fills the window; the pin remains.
- Tabs in different groups may form a pair within one Space. Each tab keeps its group.
- Turning off the Settings switch shows one tab at a time but keeps split pairs. Turning the switch on again restores them.
- If a pair contains a private tab, a restart restores its normal member alone and does not restore the pair.
- Both visible pages stay awake. Snoozing one member ends its pair, and the other member fills the window.
- Selecting another tab while a split has an empty pane cancels the pending split.
- If a tab from one pair replaces a pane of another pair, it leaves its first pair. The two former partners stay open as single tabs.
- Reordering, pinning, or unpinning a member does not break its pair. Collapsing a member's tab group also keeps the pair.
- **Close Other Tabs** closes the other member as well as every other tab. The kept tab fills the window.
- If the page area becomes too narrow for two useful panes, Search shows the focused tab alone and keeps the pair. The split returns when the page area is wide enough.
