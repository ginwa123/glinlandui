# MVVM, the way Jetpack Compose does it

This example is a todo list — the smallest app that still has the shape a real one has. It exists to answer one
question: **what does MVVM look like in an immediate-mode toolkit?**

Compose is declarative and glinlandui re-declares the tree every frame, so the two agree more than they look:
a composable is a function of the state, the ViewModel is the only thing that writes the state, and a widget
raises an intent instead of mutating anything. What changes is the *mechanism* — there is no diffing runtime,
so `collectAsState` becomes "read the value and ask for a frame", and `remember` becomes a keyed slot table
instead of a positional one.

Run it:

```sh
zig build run-todo          # the window
zig build test-todo         # the module's tests + the E2E suite, headless
```

---

## The Compose app, line by line

| Compose | here | what it is |
|---|---|---|
| `data class TodoUiState` | `state.zig` → `TodoUiState` | one value: the input and the rows. Copied on every change, comparable, bounded |
| `it.copy(input = text)` | `withInput` / `withTodo` / `withoutTodo` / `withToggled` | a pure function from a state to the next state. No mutation, no aliasing |
| `MutableStateFlow<T>` | `flow.zig` → `MutableStateFlow(T)` | one value; `set`/`update` publish only when the value actually differs |
| `_state.update { ... }` | `flow.update(arg, reduce)` | the reducer reads the current value and returns the next one |
| `StateFlow<T>` (read-only) | `flow.zig` → `StateFlow(T)` | the shape a view is given: it can read, not publish |
| `class TodoViewModel : ViewModel()` | `view_model.zig` → `TodoViewModel` | the only writer. Every public function is an intent: `onInputChange`, `add`, `remove`, `toggle` |
| `onCleared()` | `TodoViewModel.onCleared` | called by the store when the screen goes away |
| `ViewModelStore` | `view_model.Store(T)` | one instance per screen, created on first use, cleared once |
| `viewModel()` | `App.vm()` | the store's instance, looked up from the composition's owner |
| `remember { ... }` | `composition.remember(T, key, initial)` | a value that survives the frame, in a slot keyed by the id the element already needs |
| `collectAsState()` | `composition.collectAsState(T, &flow)` | read now, subscribe once; a publish sets `invalidated` and asks for a frame |
| `LaunchedEffect(key)` | `composition.effect(key, signature, ctx, run)` | run on the first frame, and again when the signature changes |
| `setContent { ... }` | `composition.setContent(App.content)` | a composable handed to a `Host` as its root function |
| `Modifier.padding(16.dp)` | `Modifier.padding(16)` | a value you chain, then fold into a widget's props. Layout is in points, which *are* dp |
| `Modifier.fillMaxSize/Width/weight` | same names in `modifier.zig` | `weight` grows along the parent's main axis, so `apply` is told the parent |
| `MaterialTheme { }` | `theme.zig` → `Theme` | a colour scheme and a type scale passed down. Components take colours as props, so a theme is a value |
| `Surface(Modifier.fillMaxSize())` | `theme.Surface` | the root every screen sits on |
| `@Composable fun TodoScreen()` | `view.TodoScreen(scope)` | a function of the state. `*Scope` is the hidden `Composer` + `CompositionLocal` bundle |
| `TextField(value, onValueChange)` | `view.textField` | a controlled field: the model owns the value, the editor owns the caret |
| `LazyColumn { itemsIndexed(..) }` | `view.todoList` + `table.visible` | declare the rows the viewport intersects, with one spacer above and one below |
| `Row { Checkbox; Text; TextButton }` | `view.todoRow` | one row: a checkbox, the title, a Delete button |
| `MainActivity.onCreate` | `app.zig` → `App` | the store, the composition, and the event routing |
| `setContent { ... }` in the Activity | `main.zig` | the window, the `Host`, and the composable it renders |

---

## The files

```
examples/todo/
├── root.zig           the module's surface — `@import("todo")` is the whole app
├── main.zig           the entry point: window + host + setContent
├── app.zig            the Activity: store, composition, key and text routing
├── view.zig           the composables: TodoScreen, the header, the list, a row
├── view_model.zig     TodoViewModel (intents) + Store(T) (viewModel())
├── state.zig          TodoUiState, Todo, Text — the data class and its copy() functions
├── flow.zig           StateFlow / MutableStateFlow
├── composition.zig    remember, collectAsState, effect, setContent
├── modifier.zig       padding, fillMaxSize, fillMaxWidth, weight
├── theme.zig          MaterialTheme: colours, type scale, Surface
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
