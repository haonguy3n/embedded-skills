# C++ rules (full)

The rule book behind SKILL.md. Examples name classes from the source project (a camera service) only to show the
shape; replace them with the target project's own.

## Contents
1. Layout · 2. Naming · 3. Header documentation · 4. Class design · 5. Roles · 6. Patterns · 7. Ownership ·
8. Threading · 9. Errors · 10. Function length · 11. Efficiency · 12. Single homes · 13. Formatting and the gate ·
14. Tests

---

## 1. Layout

```
Libs/<Name>/
├── CMakeLists.txt
├── include/<Name>/*.h      public headers; sub-areas are PascalCase dirs (include/Transport/Rtsp/)
├── src/<Name>/*.cpp        mirrors include/
└── test/*.cpp              standalone self-checks (section 14)
Apps/<App>/
├── CMakeLists.txt
├── include/<App>/*.h
├── src/*.cpp, src/main.cpp
└── test/*.cpp
```

- One class per file, named exactly after the class (`StreamManager.h`, `StreamManager.cpp`). PascalCase file and
  directory names, `.h` / `.cpp`, `#pragma once`, no license header.
- Includes use angle brackets with the module prefix, a module's own headers included: `#include <Pipeline/Builder.h>`.
  A `.cpp` includes its own header first; then a blank line, then other in-house modules, then third-party, then std.
- Every library has the same CMake shape: a STATIC library named after the module, linking only what it uses, PUBLIC
  only for what its headers expose.

  ```cmake
  add_library(Update STATIC
  	src/Update/UpdateController.cpp)
  target_include_directories(Update PUBLIC include)
  target_compile_options(Update PRIVATE -Wall -Wextra)
  target_link_libraries(Update PUBLIC Base)
  if(BUILD_TESTING)
  	add_self_check(UpdateControllerCheck test/UpdateControllerCheck.cpp LIBS Update)
  endif()
  ```

- Dependencies point one way, down a layer list written in the design doc. A library never includes a header from a
  library above it. When it needs something from above, it defines an interface and receives an implementation
  (constructor injection): a lower `MetaPublisher` calls an `IMetaObserver` that a higher `RulesService` implements.

## 2. Naming

| What | Rule | Example |
|---|---|---|
| namespace | one per library, PascalCase, equal to the library name | `namespace Pipeline` |
| internal helpers in a header | `namespace Detail` | `Base::Detail::TaskQueue` |
| class | PascalCase | `StreamManager` |
| interface | `I` prefix, pure virtual | `ICaptureAdapter` |
| struct / enum / type alias | PascalCase + `_t` | `CameraConfig_t`, `enum class FrameMemory_t` |
| enum values | camelCase (`enum class`) | `FrameMemory_t::native` |
| function / method | PascalCase | `CaptureStage()` |
| private or protected method | PascalCase + `_` | `ConstructPlatform_()` |
| free function local to a `.cpp` | PascalCase in an unnamed namespace (not `static`) | `RtspConfig()` |
| member variable | `m_` + Hungarian + camelCase | `m_pPlatform`, `m_bStarted`, `m_rQueue`, `m_frames` |
| const member | `mk_` | `mk_ident` |
| static non-const | `s_` | `s_pLogger` |
| constant | `k_` + camelCase, optional unit suffix | `k_watchdogPeriod_s`, `k_maxLine_B` |
| local / parameter | camelCase + Hungarian | `pSource`, `rConfig`, `bInline`, `oClassId` |
| public struct field | plain camelCase | `int width;` |
| template parameter | `T` or `NameT` | `template <typename MetaT>` |
| macro | UPPER_SNAKE; avoid new ones | |

Hungarian letters: `b` bool, `p` pointer (raw or smart), `r` reference, `o` `std::optional`. Plain values (ints,
strings, containers) take no letter. Getters are PascalCase (`BoundAddress()`).

Keep the external spelling for: overrides of third-party virtuals, C callback signatures, JSON keys, config keys, log
text, and names inside strings another tool parses.

## 3. Header documentation

A header must explain its design without anyone opening the `.cpp`.

- **Every class, interface and struct** starts with a `/** @brief ... */` block: its **role** (section 5) and its
  **pattern** (section 6), and why it has that shape here; who creates and destroys it; which thread calls it; the
  seam it offers (what can be swapped or mocked). A few lines; say why, not what the code says.
- **Every public method, and every protected method of an interface**: a one-sentence `@brief`; `@param[in]`,
  `@param[out]` or `@param[in,out]` per parameter; an `@return` that states the success value **and** the failure
  (`std::unexpected`) case. Refer to parameters as `@p name`. Note preconditions and the calling thread when it
  matters. A trivial getter may use one `///` line.
- **Members** get a trailing `///<` note when the name alone does not give the units, ownership or invariant.
- No `@throws` (nothing throws). The `.cpp` does not repeat the header's API docs.

```cpp
/**
 * @brief The machine the service runs on, as an Abstract Factory: creates every part that differs between the
 * target and a dev host, so no other code asks which machine it is on.
 *
 * Created by SystemManager through CreatePlatform() before anything else, owned there by unique_ptr and rebuilt on
 * reload; used on the main thread only. The seam: a new machine is one subclass plus one line in CreatePlatform's table.
 */
class IPlatform
{
public:
	/**
	 * @brief Creates the update backend for this machine.
	 * @param[in] rConfig The loaded config; the host backend stores uploads in @p rConfig.hostUpdateDir.
	 * @return The backend, never null; the caller owns it.
	 */
	virtual std::unique_ptr<IUpdateAdapter> CreateUpdateBackend(Config_t const& rConfig) const = 0;
};

/**
 * @brief Selects the platform named by the config.
 * @param[in] rSetting "target", "host", or "auto" (the first available).
 * @return The platform; or std::unexpected "unknown platform '<name>'" for an unknown @p rSetting.
 */
std::expected<std::unique_ptr<IPlatform>, std::string> CreatePlatform(std::string const& rSetting);
```

In `.cpp` files use `//` inside bodies, and write down *why* the code has its shape, especially anything learned the
hard way on the target. Namespace closers are `} // namespace X`.

## 4. Class design

- **Rule of five.** Declare all five special members or none, as `= default` or `= delete`. An interface deletes copy
  and move and has a protected default constructor. (clang-tidy `cppcoreguidelines-special-member-functions`.)
- **Identity objects are not copied**: anything holding a thread, an OS handle, a callback registration or a
  reference-counted foreign object deletes copy and move; share it by reference or pointer.
- Single-argument constructors `explicit`; every override says `override` (destructors too); leaf strategies `final`.
- No `using namespace` at namespace scope.
- Small types by value; `std::string_view` for non-owning string parameters when it does not force a copy.
- Composition over inheritance; inherit only from interfaces.
- Capabilities belong to the class that has them: callers ask the object (`CheckAvailable()`), never compare a type name.

## 5. Roles

Each class plays one role and its name ends with it. Classes with no role name what they are (values, parsers,
builders: `SdpBuilder`, `RtspMessageParser`) and still document their pattern.

| Role | What it does |
|---|---|
| Composition root | builds, wires, owns and tears down every subsystem in dependency order (one per process) |
| Manager | owns a subsystem's lifecycle and its set of controllers; the subsystem's face to the rest |
| Controller | the rules or state machine of **one** thing |
| Service | the interface a consumer calls over per-item controllers; validates the item and holds cross-item rules |
| Adapter | a thin shim over one external backend, no policy (often RAII over a foreign resource) |
| Monitor | watches something and reports on it or acts on its health |
| Handler | one protocol operation |
| Server | owns the sockets of one wire protocol and hands content elsewhere |

## 6. Patterns

Name the pattern in the header and say why it fits. The ones that keep recurring:

| Pattern | Typical use | Why |
|---|---|---|
| Composition root + constructor injection | the app's `SystemManager::Construct_()`, one call per step with `// Requires ...` | one place knows the graph; reload is destroy + construct |
| Abstract Factory | `IPlatform` → `TargetPlatform`, `HostPlatform` | a family of machine-specific parts must come from the same machine |
| Registration table | a config string → constructor table | selection in one place; a new entry is one line |
| Strategy | one interface per varying behaviour (source kinds, per-machine elements) | each case is one interchangeable class |
| Builder over typed values | composing a command line / pipeline / query from `Element`, `Caps`, `Chain`-like values | separators, quoting and names written once, not at every `+` |
| Facade | a small Service API in front of controllers | the protocol layer never sees the controllers |
| Ports and adapters | a lower stack owns a port interface; the app provides the adapter | the stack knows nothing of the app's media; a harness can fill the port |
| Observer (publish-subscribe) | frame or event sources with subscriptions | consumers never see producers; subscriptions decide what runs |
| Producer–consumer, bounded, drop-oldest | a real-time callback → a named worker | a real-time thread never waits on a slow consumer; for live data the newest item matters |
| Open/closed extension point | a new metadata kind = one class + one registration line | |
| RAII lease / handle | refcounted buffers, file descriptors, foreign objects, scope-exit guards | no manual release on early returns |
| Monitor object | `Synchronized<T>` | data reachable only with its lock held |
| Watchdog | a stall monitor, a liveness probe per thread, the init system's watchdog | hung parts are restarted, not waited on |
| Template Method | a base that owns a lifecycle and calls subclass hooks | subclasses are only their hooks |

## 7. Ownership

- `std::unique_ptr` in the composition root; members declared in construction order; teardown order documented
  (publishers stop before their sinks; pools before the controllers their jobs use).
- References everywhere else, constructor-injected, documented "(outlives this)". Do not store a pointer you don't own
  unless it is optional.
- `std::shared_ptr` only where async operations genuinely share a lifetime, and each such use is listed in the
  guidelines (buffers leased to consumers, network channels). Nowhere else.
- Every C resource has an owning handle; cleanup that is not a class uses a scope-exit guard. No bare release calls on
  paths that can return early.

## 8. Threading

- Threads only from the threading library: a `Worker` (one thread, ordered tasks), a `WorkerPool` (N threads,
  independent jobs), a `LoopThread` (a long-lived body). Each is named (≤ 15 chars on Linux) and owned; a task that
  throws anyway is logged with the thread's name. No raw `std::thread` / `std::jthread` elsewhere (the gate greps).
- Every queue is bounded with an explicit full policy: block, drop-oldest or drop-newest. Decide what happens when full.
- Name each thread's job in the docs (the main loop, the I/O thread, protocol pools, real-time callbacks). Real-time
  callbacks copy values out, never block, log nothing per item, and hand off through a bounded queue. Blocking calls
  run on a thread made for them, never on the main loop or the I/O thread.
- Cross-thread state lives in a `Synchronized<T>` or an atomic (relaxed for plain counters).
- Declare a thread member **last**: it starts after what it uses and stops first.
- Run threading changes under ThreadSanitizer (a `tsan` preset) and treat every report as real.

## 9. Errors

- A fallible function returns `std::expected<T, std::string>` or a domain error type when the caller needs more than
  text; `std::expected<void, E>` with `return {};` for no value. Never bool + out-parameter.
- Do not throw. Handle or propagate every result; a deliberately non-fatal failure is logged and dropped explicitly.
- The error text reaches people (logs, sometimes the client): write it for a person, naming what and why.
- A security misconfiguration is fatal at startup and never falls back silently; a config file that exists but cannot
  be parsed stops the service rather than running on defaults.

## 10. Function length

At most 30 lines per function (self-checks exempt), enforced by clang-tidy `readability-function-size`
(`LineThreshold: 31`, counted brace to brace). Split by what the code does — the composition root is the model: one
call per step.

## 11. Efficiency

Write down the machine's real constraints (in the source project: 8 cores and RAM shared with the GPU and encoders, so
every frame copy costs bandwidth the hardware also needs). Then:
- Keep data where the hardware wants it; avoid copies on hot paths; no per-item allocation where avoidable; `reserve()`.
- Don't fork from a multi-threaded process; read `/proc` and sysfs instead of shelling out.
- **Measure, don't argue**: compare load and throughput before and after, on the target, and keep the numbers.

## 12. Single homes

Keep a table in the guidelines: each shared concern and its one home. Use it or extend it; never re-implement it.
Typical rows: building command lines / pipelines; machine differences; the clock; JSON; config loading; protocol
constants (shared by both sides of the wire); names other code looks up; threads and queues; mutex-guarded data,
fds, scope cleanup, logging; developer tools (one command with subcommands, e.g. `tools/<name> release|check|...`).
When review finds a second home, merge it into the first.

## 13. Formatting and the gate

- Never hand-format: `clang-format -i <files>` with the repo-root `.clang-format` (tabs, Allman braces, 120 columns,
  east const `int const`, `T* p`, braces on every `if`).
- The gate runs, each step reporting nothing: clang-tidy (bugs, analyzer, performance, naming, function size, rule of
  five, `explicit`), cppcheck (what clang-tidy misses), house rules by grep (no `throw`, threads only from the library,
  no build-host paths in generated files), and the other languages' linters (ruff, shellcheck, the UI type check,
  clippy). It needs a debug build's `compile_commands.json`.
- A false positive is suppressed on its line with the reason: `// NOLINT(<check>): <why>`,
  `// cppcheck-suppress <id> ; <why>`. A check that is wrong everywhere is disabled in `.clang-tidy` with its reason in
  the file's header comment.

## 14. Tests

- No framework. A self-check is a standalone, assert-based `.cpp` in `Libs/<Name>/test/`, declared with
  `add_self_check(<Name> test/<Name>.cpp LIBS <lib>)`, which keeps asserts on in release builds (`-UNDEBUG`) and
  registers it with CTest. Its header comment says what it checks and the exact command that runs it.
- Every non-trivial piece of logic leaves one check behind. Pull logic out of hardware-only code into plain functions
  so a host can check it; inject clocks, file roots (`/proc`, `/sys`) and backends to make it checkable.
- The running system is tested separately (for example pytest against a running instance or a device), with tests
  named for the behaviour, cleaning up after themselves, and marked by what they need (disruptive, needs hardware...).
