Sign-in field fixtures: real-world forms, trimmed to the parts that matter,
for Forms.script's judge (FormFieldCorpusTests, and field_corpus.py in a
hidden probe). Each file's first line says where the page lives and what the
box marked data-probe is offered:

  <!-- url: https://… expect: none|exact|wide name: true|false -->

none: no accounts. exact: only accounts kept for this very host. wide: also
the accounts of the site's other hosts (a real sign-in field). name: a pick
puts in the name alone (a first step with no password box).
