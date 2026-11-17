# Godot 4.7.2 shutdown diagnostics

These patches target **Godot source** commit
`ed1daf0bf001b61586d9930840f2f1394092c079`, not the game's GDScript files.
They are not automatically applied and do not replace the official engine.
Do not apply both patches together to an unmodified tree.
`.gitattributes` treats their unified-diff context as patch data for whitespace
checking; each patch is separately checked against the exact engine source.

- `godot_4_7_2_finish_iterator_probe.patch`: diagnostic **intentional abort**
  if releasing the current script destroys the next iterator element. Records
  both resource paths before a use-after-free can occur. Use only in a separate
  diagnostic engine build, never as the game's engine.
- `godot_4_7_2_script_finish.patch`: proposed engine fix; holds script references
  until dependency breaking and list cleanup finish. This is separate from the
  project changes and requires engine-level review and wider engine regression.

Use a separate exact-source clone and run `git apply --check <absolute-patch>`
before applying. The investigated Windows template build used:

```text
python -m SCons platform=windows target=template_debug dev_build=yes
 debug_symbols=yes optimize=none disable_path_overrides=no
 disable_3d=yes vulkan=no d3d12=no opengl3=no -j4
```

Run from a VS x64 developer environment. This headless diagnostic template does
not implement the rendered editor. Preserve each matching EXE/PDB pair before
rebuilding; never use its PDB with an official binary.

The existing `tests/integration/native_lifecycle_probe.tscn` offers `physics`
and `player` modes. To exclude local author content, use a disposable tracked-only
project copy for reduction. Do not change the real project's Autoloads.

See [the investigation report](../../docs/step7_stability_round2.md) for the
actual dump stacks, A/B profiles, official-binary failures and limitations.
Godot engine source and these source excerpts are under its MIT license.
