# MVVM, the way Jetpack Compose does it

This example is a todo list — the smallest app that still has the shape a real one has. It exists to answer one
question: **what does MVVM look like in an immediate-mode toolkit?**

Compose is declarative and glinlandui re-declares the tree every frame, so the two agree more than they look:
a composable is a function of the state, the ViewModel is the only thing that writes the state, and a widget
raises an intent instead of mutating anything. What changes is the *mechanism* — there is no diffing runtime,
so `collectAsState` becomes "read the value and ask for a frame", and `remember` becomes a keyed slot table
instead of a positional one.

The runtime is **the engine's**, not this folder's: `state_flow`, `composition`, `view_model` and `theme` ship
with glinlandui, so the next app gets them without copying anything. What is left here is what is genuinely
this app's — its state, its intents, its view, its palette.

Run it:

```sh
zig build run-todo          # the window
zig build test-todo         # the app's own tests + the E2E suite, headless
```

---

## The Compose app, line by line

### From the engine (`glinlandui.*`)

| Compose | glinlandui | what it is |
|---|---|---|
| `MutableStateFlow<T>` | `state_flow.MutableStateFlow(T)` | one value; `set`/`update` publish only when the value actually differs |
| `_state.update { ... }` | `state.update(arg, reduce)` | the reducer reads the current value and returns the next one |
| `StateFlow<T>` (read-only) | `state_flow.StateFlow(T)` | what a view is handed: `get` and `collect`, no `set` |
| `remember { ... }` | `composition.remember(T, key, initial)` | a value that survives the frame, in a slot keyed by the id the element already needs |
| `collectAsState()` | `composition.collectAsState(T, flow)` | read now, subscribe once; a publish sets `invalidated` and asks for a frame |
| `LaunchedEffect(key)` | `composition.effect(key, signature, ctx, run)` | run on the first frame, and again when the signature changes |
| `setContent { ... }` | `composition.setContent(App.content)` | a composable handed to a `Host` as its root function |
| `ViewModelStore` / `viewModel()` | `view_model.Store(T)` + `App.vm()` | one instance per screen, created on first use, `onCleared` on leave |
| `MaterialTheme { }` | `theme.Theme` (+ `theme.dark` / `theme.light`) | colour roles and a type scale, passed down as a value |

### From this app

| Compose | here | what it is |
|---|---|---|
| `data class TodoUiState` | `state.zig` → `TodoUiState` | one value: the input and the rows. Copied on every change, comparable, bounded |
| `it.copy(input = text)` | `withInput` / `withTodo` / `withoutTodo` / `withToggled` | a pure function from a state to the next state. No mutation, no aliasing |
| `class TodoViewModel : ViewModel()` | `view_model.zig` → `TodoViewModel` | the only writer. Every public function is an intent: `onInputChange`, `add`, `remove`, `toggle` |
| `@Composable fun TodoScreen()` | `view.TodoScreen(scope)` | a function of the state. `*Scope` is the hidden `Composer` + `CompositionLocal` bundle |
| `TextField(value, onValueChange)` | `view.textField` | a controlled field: the model owns the value, the editor owns the caret |
| `LazyColumn { itemsIndexed(..) }` | `view.todoList` + `table.visible` | declare the rows the viewport intersects, with one spacer above and one below |
| `Row { Checkbox; Text; TextButton }` | `view.todoRow` | one row: a checkbox, the title, a Delete button |
| `MainActivity.onCreate` | `app.zig` → `App` | the store, the composition, and the event routing |
| `setContent { ... }` in the Activity | `main.zig` | the window, the `Host`, and the composable it renders |

### What has no equivalent, on purpose

**`Modifier`.** Compose needs it because its composables take no layout parameters. Every widget here takes a
props struct, and `box.BoxProps` already carries `pad`, `w`, `h`, `gap` and `bg` — so
`Modifier.padding(16.dp).fillMaxWidth()` is just `.pad = 16, .w = .grow`. A wrapper on top would be a second
vocabulary for the same thing.

**`Surface`.** It is a box painted with a background role: five lines in `theme.zig`, and it reads better where
the palette is.

---

## The files

```
examples/todo/
├── root.zig           the module's surface — `@import("todo")` is the whole app
├── main.zig           the entry point: window + host + setContent
├── app.zig            the Activity: store, composition, key and text routing
├── view.zig           the composables: TodoScreen, the header, the list, a row
├── view_model.zig     TodoViewModel — the intents, and nothing else
├── state.zig          TodoUiState, Todo, Text — the data class and its copy() functions
├── theme.zig          the app's palette: the engine's dark theme with its own accent
└── todo_test.zig      the E2E suite: the real App, driven headlessly
```

Each file carries its own tests, so `zig build test-todo` runs the whole example without a window.

---

## Three things an immediate-mode app must get right

These are not Compose ideas; they are the constraints that replace Compose's runtime. Each one is a bug this
example hit and then a test that keeps it fixed.

**1. Text handed to Clay must outlive the declare.** A composable returns before the frame is laid out, so a
label built from a stack value points at dead memory by the time it is drawn. The state is a value, so a row's
title is copied into the frame's scratch with `frame.formatText`. A literal, or the App's own field buffer,
needs no copy.

**2. A callback's context must outlive the frame.** Clicks are dispatched *after* the declare returns, so a
`*Scope` that lives on `TodoScreen`'s stack is already gone. Intents therefore carry the ViewModel (or a
`RowCtx` remembered in a composition slot), never a frame-local struct.

**3. Register a click target before you declare it.** `topmostAt` lets the *later* entry win a tie, and a
button declared inside a row registers after the row does. So the row registers its own target first, and the
Delete button — registered inside it, later — wins the hit test. Without that order a click on Delete would
also toggle the row underneath it, which is exactly what the E2E suite asserts cannot happen.

---

## What the E2E suite proves

`todo_test.zig` drives the real `App` through the real `Host` with `testing.Driver` — no window, no compositor:

- the empty state is **drawn**, not just modelled;
- typing reaches the model, Enter adds a row, and the frame shows it;
- a blank Enter publishes nothing (the distinct-value gate, observed through `revision()`);
- clicking a row toggles it, and the footer counts it;
- Delete removes its own row and does not toggle it;
- a publish invalidates the composition, and the next frame clears the flag.

Asserting only on `vm.uiState()` would pass with a blank window, so every one of these also checks the frame.
