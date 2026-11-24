let hidden = 0;

for (const name of ["Components", "Profiler"]) {
  chrome.devtools.panels.create("Fixture " + name, "", "panel.html", (panel) => {
    panel.onHidden.addListener(() => { hidden += 1; });
    panel.onShown.addListener((panelWindow) => {
      if (!Number.isInteger(chrome.devtools.inspectedWindow.tabId)) {
        document.title = "No inspected tab ID";
        return;
      }
      const contents = panelWindow.document.getElementById("content").textContent;
      chrome.devtools.inspectedWindow.eval("document.title", (title, error) => {
        if (error) {
          document.title = "Eval failed: " + (error.description || error.value || error.code);
        } else {
          document.title = name + " | " + title + " | " + contents + " | hidden:" + hidden;
        }
      });
    });
  });
}
