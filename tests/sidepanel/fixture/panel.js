// An export the way panels do it: a blob of their own, downloaded through a
// link. A download link must stay a download, not become the panel's page.
window.exportBlob = () => {
  const a = document.createElement('a')
  a.href = URL.createObjectURL(new Blob(['{ "exported": true }'], { type: 'application/json' }))
  a.download = 'export.json'
  document.body.appendChild(a)
  a.click()
  return a.href
}
