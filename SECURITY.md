# Security

Search handles your history, your cookies and every page you open, so a
hole in it matters more than most bugs. If you find one, please tell us
privately first.

## How to report

Report it on GitHub: the repository's **Security** tab ›
[**Report a vulnerability**](https://github.com/Paul0k/Search/security/advisories/new).
Only the maintainers see it. Say what you found, where in the
code, and how to see it happen. A proof of concept
that stays on your own machine is welcome; please don't try it on other
people's accounts or data.

Please don't open a public issue or pull request that describes the problem
until a fixed version is out. A pull request that only fixes it, without
spelling out the attack, is fine.

## What happens next

- You get an answer from the person who makes Search, not a form.
- The fix goes into `main`; this fork has no updater, so people get it
  by pulling and building again.
- Once it is out, you're thanked by name in the changelog, unless you'd
  rather not be.

## What counts

Anything that lets a web page, an extension, another app or someone on the
network do more than they should: read files, cookies or
history, get around a permission, open another app without asking, or
change the app itself. The extensions layer, `./bench`, `./bench-mcp` and
`./search-mcp` are all in scope.

A site that doesn't work, or an extension that behaves differently from
Chrome, is a bug rather than a security problem: open an
[issue](https://github.com/Paul0k/Search/issues) for those.
