# MVVM, the way Jetpack Compose does it

This example is a todo list — the smallest app that still has the shape a real one has. It exists to answer one
question: **what does MVVM look like in an immediate-mode toolkit?**

Compose is declarative and glinlandui re-declares the tree every frame, so the two agree more than they look:
a composable is a function of the state, the ViewModel is the only thing that writes the state, and a widget
raises an intent instead of mutating anything. What changes is the *mechanism* — there is no diffing runtime,
so `collectAsState` becomes "read the value and ask for a frame", and `remember` becomes a keyed slot table.

The runtime is **the engine's**, and so are the widgets: `state_flow`, `composition`, `view_model`, `theme`,
`components.input` and `components.list` ship with glinlandui. What is left here is what is genuinely this
app's — its state, its intents, its view.

```sh
zig build run-todo          # the window
zig build test-todo         # the app's own tests + the E2E suite, headless
```

---

## The Compose app, line by line

### From the engine

| Compose | glinlandui | what it is |
|---|---|---|
| `ViewModelStore` / `viewModel()` | `view_model.Store(T)` + `App.vm()` | one instance per screen, created once, `onCleared` on leave |
| `MaterialTheme { }` | `theme.Theme` (+ `theme.dark` / `theme.light`) | colour roles and a type scale, passed down as a value |
| `TextField(value, onValueChange)` | `input.textField(&field)` | one struct: the look, the draft, the caret, the keyboard, and `on_change`/`on_submit` |
| `LazyColumn { itemsIndexed(..) }` | `list.list(props, items, ctx, renderItem)` | rows with ids, hover and per-row clicks |

### From this app

| Compose | here | what it is |
|---|---|---|
| `data class TodoUiState` | `state.zig` → `TodoUiState` | one value: the rows. Replaced by an intent, read by the frame, bounded |
| `MutableStateFlow<T>` + `_state.update { }` | `view_model.zig` → `state: TodoUiState` | a plain field. An intent assigns it; there is no observable and nothing to collect |
| `it.copy(todos = ...)` | `withTodo` / `withoutTodo` / `withToggled` | a pure function from a state to the next state |
| `class TodoViewModel : ViewModel()` | `view_model.zig` → `TodoViewModel` | the only writer. Every public function is an intent: `add`, `remove`, `toggle` — and it owns the screen's own state: the field and the row contexts |
| `@Composable fun TodoScreen()` | `view.TodoScreen(scope)` | a function of the state. `*Scope` is the hidden `Composer` + `CompositionLocal` bundle |
| `Row { Checkbox; Text; TextButton }` | `view.renderRow` | one row: a checkbox, the title, a Delete button |
| `MainActivity.onCreate` | `app.zig` → `App` | the store, the theme, and the composition — nothing else |
| `setContent { ... }` in the Activity | `main.zig` | the window, the `Host`, and the composable it renders |

---

## What has no equivalent, on purpose

**The composition runtime.** There is none: `remember`, `collectAsState`, `LaunchedEffect` and `setContent`
exist in Compose because a composable may be skipped, cached or re-ordered. Here the frame *is* the
recomposition — it reads the state and declares the tree, the window repaints after every key and pointer
event, and view-local state that must survive a frame is simply a field on the ViewModel. The root function is
`App.content` itself, so `Host.init(gpa, &app, App.content)` is `setContent { }`.

**`Modifier`.** Compose needs it because its composables take no layout parameters. Every widget here takes a
props struct, and `box.BoxProps` already carries `pad`, `w`, `h`, `gap` and `bg` — so
`Modifier.padding(16.dp).fillMaxWidth()` is just `.pad = 16, .w = .grow`.

**Nothing to reconcile.** The field holds the caret and the selection; the STATE holds the draft, because
`value` is a prop. Type a key and the field reports it (`on_change` → `vm.onInputChange`); the next frame
passes `state.input` back in, and since the value did not change under the field, the caret stays put. Press
Enter and the field raises `on_submit`: `true` means the intent took the draft, so the field clears itself and
reports the empty text — a blank title is refused and stays exactly where it was.

**`Surface`.** It is a box painted with a background role, and it reads better where the palette is.

---

## The files

```
examples/todo/
├── root.zig           the module's surface — `@import("todo")` is the whole app
├── main.zig           the entry point: window + host + setContent
├── app.zig            the Activity: the store, the theme, and the composition
├── view.zig           the composables: TodoScreen, the header, the list, a row
├── view_model.zig     TodoViewModel — the intents, and the screen's own state (the field, the row contexts)
├── state.zig          TodoUiState, Todo, Text — the data class and its copy() functions
└── todo_test.zig      the E2E suite: the real App, driven headlessly
```

---

## The two lifetimes the app still owns

The third one — a row's click target is registered before its box, so a button inside the row wins — is
`components.list`'s job now. These two are the app's, and each is a bug this example hit:

**1. Text handed to Clay must outlive the declare.** A composable returns before the frame is laid out, so a
label built from a stack value points at dead memory. The state is a value, so a row's title is copied into the
frame's scratch with `frame.formatText`. A literal, or the field's own buffer, needs no copy.

**2. A callback's context must outlive the frame.** Clicks are dispatched *after* the declare returns, so a
`*Scope` on `TodoScreen`'s stack is already gone. So every context points at the ViewModel instead: the field
and the per-row contexts (`field`, `row_ctxs`) are its fields, and the ViewModel outlives the frame by design.
The Add button needs no context of its own — it calls `vm.field.submit()`, the same intent Enter raises.

---

## What the E2E suite proves

`todo_test.zig` drives the real `App` through the real `Host` with `testing.Driver` — no window, no compositor:

- the empty state is **drawn**, not just modelled, and the field owns the keyboard from the first frame;
- typing reaches the field through the ENGINE (no key handler is registered anywhere), Enter adds a row,
  the frame shows it, and the field and the model are both empty again;
- a blank Enter adds nothing and leaves the draft where it was;
- clicking the checkbox toggles the row, and the footer counts it;
- Delete removes its own row and does not toggle it.

Asserting only on `vm.uiState()` would pass with a blank window, so every one of these also checks the frame.
