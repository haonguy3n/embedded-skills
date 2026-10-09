---
name: cpp-house-rules
description: >-
  House rules for writing and reviewing modern C++ (C++20/23) services, especially embedded or long-running Linux
  daemons: one-library-per-module layout, PascalCase + m_/k_/Hungarian naming, every class header naming its role
  and design pattern, errors as std::expected with no exceptions, functions of at most 30 lines, explicit ownership
  (unique_ptr in one composition root, references elsewhere), threads only from one threading library with bounded
  queues, one single home for every shared concern, machine differences behind one platform interface, an assert-based
  self-check for every piece of logic, a static-analysis gate that must print "clean", and small verified commits.
  Use this skill whenever writing, refactoring or reviewing C++ in a project that follows these rules or wants to
  adopt them; when setting up a new C++ project's structure, CMake libraries, clang-format/clang-tidy or test layout;
  when the user asks for "our coding rules", "house style", "project conventions", or wants a CODING-GUIDELINES.md,
  .clang-tidy or a code-check gate for another repository - even if they do not name this skill.
---

# C++ house rules

These rules come from a production camera service (C++23, GStreamer, ONVIF, an embedded Linux image) that was also
built to be *learned from*. They aim at three things at once: code a newcomer can understand from its headers alone,
code that a machine can check (so rules are enforced, not remembered), and changes small enough to verify.

The rules are opinions with reasons. When you apply them to another project, keep the reasons; adapt the specifics
(naming prefixes, line limit, library names) if the project already has its own and the team prefers them. Never
mix two styles in one codebase: a rule the code disagrees with is fixed in the code you touch.

## How to use this skill

1. **Find out which situation you are in.**
   - *An existing project that already follows these rules* (it has a `docs/CODING-GUIDELINES.md`, `m_`/`k_` names,
     `std::expected`, a check script): read the project's own guidelines first; they win over this file where they
     differ, since they hold the project-specific single homes and exceptions.
   - *A new project, or one adopting the rules*: follow "Bootstrapping a project" below.
   - *A review*: walk the checklist in "Reviewing a change".
2. **Before writing code**, read `references/cpp-rules.md` sections for what you are about to touch (layout and naming
   for a new class, threading before touching a queue, ownership before storing a pointer). It is the full rule book
   with examples; this file is the summary.
3. **After writing code**, run the project's gate (formatter, then the check script) and its self-checks, then commit
   per `references/process.md`.

## The rules in one page (why in brackets)

**Structure**
- Each module is a library: `Libs/<Name>/{include/<Name>/*.h, src/<Name>/*.cpp, test/*.cpp, CMakeLists.txt}`; apps in
  `Apps/<Name>/`. One class per file, named after the class. Includes are `#include <Module/Header.h>` even inside the
  module. [Any file is found from its class name; a header's module is visible in every include.]
- Dependencies point one way, down a documented layer list. A library never includes a header from a layer above; it
  defines an interface and receives an implementation (injection). [Prevents cycles; keeps lower layers testable.]
- One composition root (e.g. `SystemManager`) builds the whole object graph in dependency order, one call per step,
  each step commented with what it requires; reload = destroy + construct. [Only one place knows the graph.]

**Naming** (enforced by clang-tidy's identifier-naming)
- Types, functions, methods: PascalCase. Private/protected methods end in `_`. Structs, enums, aliases end in `_t`.
  Interfaces start with `I`. Enum values camelCase.
- Members `m_` + Hungarian letter + camelCase: `b` bool, `p` pointer (raw or smart), `r` reference, `o` optional
  (`m_pPlatform`, `m_bStarted`, `m_rSink`). Const members `mk_`, statics `s_`, constants `k_` (with a unit suffix when
  it has one: `k_timeout_ms`). Locals and parameters: camelCase with the same letters (`rConfig`, `pBuffer`).
  [The type and the ownership show at every use site.]

**Documentation**
- Every class/struct/interface header starts with a `@brief` block giving its **role** (Composition root, Manager,
  Controller, Service, Adapter, Monitor, Handler, Server) and its **pattern** (Strategy, Abstract Factory, Observer,
  Builder, Adapter, Template Method, RAII lease, producer-consumer...), and why it has that shape here; who creates
  and destroys it; which thread calls it; which seam it offers. [A newcomer learns the design from the headers.]
- Every public method: `@brief`, `@param[in|out]` per parameter, and an `@return` that states the success value and
  the failure case. No `@throws`, because nothing throws.

**Behaviour**
- Errors are values: `std::expected<T, std::string>` (or a domain error type), `std::expected<void, E>` when there is
  nothing to return. No exceptions, no bool + out-parameter. Every result is handled or explicitly dropped with a log
  line. Error text is written for a person. [Failure paths are visible in signatures and reviewed like success paths.]
- Functions are at most 30 lines; split by what the code does. [Small units are readable and testable.]
- Rule of five: declare all five special members or none; identity objects (threads, handles, sources) delete copy
  and move. Single-argument constructors `explicit`, every override says `override`, leaf classes `final`.
- Ownership: `std::unique_ptr` in the composition root, references (documented "outlives this") everywhere else,
  `std::shared_ptr` only where lifetime is genuinely shared and listed in the guidelines. RAII handles for every C
  resource; a scope-exit guard for cleanup that is not a class.
- Threads only from one threading library (Worker / WorkerPool / LoopThread style): named, owned, bounded queues with
  an explicit full policy (block / drop-oldest / drop-newest), and every task's exception logged with its thread's name.
  Callbacks on real-time threads copy values out and never block. A thread member is declared last.
- Machine and source differences live behind one interface each (an Abstract Factory for the platform, a Strategy for
  each source kind). Never branch on a type name or a config string outside that one place.
- **Single homes**: every shared concern (building a command line, a clock, JSON, a protocol constant, a registry) has
  exactly one home, listed in a table in the guidelines. Use it or extend it; never re-implement it nearby.
  [Duplication is how two "slightly different" versions of the same thing appear.]

**Proof**
- Every piece of non-trivial logic leaves one self-check behind: a standalone, assert-based `test/<Name>.cpp` that
  CTest runs (no framework). Pull logic out of hardware-only code so a plain host can check it.
- One gate (e.g. `tools/check`) runs the formatter check, clang-tidy, cppcheck, grep-based house rules (no `throw`, no
  raw `std::thread`), and the linters of every other language in the repo; it must print "clean" before a commit.
  Suppress a false positive on its line with the reason.
- Small commits, one concern each, verified in a clean worktree; the message says what changed, how it was verified,
  and where (host only, or on the target).

## Bootstrapping a project

Do these in order; each step is small and leaves the project buildable.

1. **Layout and CMake.** Create `Libs/`, `Apps/`, and a top-level `CMakeLists.txt` with the `add_self_check` helper
   from `assets/self-check.cmake` and `option(BUILD_TESTING ...)`. Use the library shape in `references/cpp-rules.md`
   §1. Add `CMakePresets.json` with at least a debug host preset that builds the checks and exports
   `compile_commands.json` (clang-tidy reads it), and sanitizer presets (ASan+UBSan, TSan) if threads are involved.
2. **Formatter and linter.** Copy `assets/clang-format` to `.clang-format` and `assets/clang-tidy` to `.clang-tidy`.
   Review the `.clang-tidy` header: it lists every disabled check with its reason; drop exceptions the new project
   does not need (it mentions GLib, boost::asio and gSOAP, which were specific to the source project; e.g. remove
   `StructIgnoredRegexp: '^soap$'`).
3. **The gate.** Copy `assets/check.sh` to `tools/check.sh` (or a `tools/<name> check` command), adjust paths, make it
   executable, and run it once on the empty project: it should print "clean".
4. **The guidelines.** Write `docs/CODING-GUIDELINES.md` from `references/cpp-rules.md`, replacing the examples with
   the project's own classes as they appear, and start the **single homes** table (even with two rows). Add the
   project's domain specifics as their own section (in the source project: GStreamer element names, zero-copy frame
   memory on the Jetson, launch strings built from typed values).
5. **The agent file.** If the team uses coding agents, add a short `CLAUDE.md`/`AGENTS.md` that links the guidelines
   and lists the rules most often missed, the build/test commands typed exactly, and the hazards (anything that can
   brick a device or lose data). Keep it current: it is read on every task.

## Reviewing a change

Walk this list; each item points at a reference section.

- Layout: right library, one class per file, module-prefixed includes, no upward dependency (cpp-rules §1).
- Names: types/methods/members/constants per the table (cpp-rules §2); the gate catches most, a reviewer catches
  misleading Hungarian letters.
- Headers: role and pattern and why; every public method documented with its failure case (cpp-rules §3).
- Errors: no `throw`, no ignored `std::expected`, error text readable (cpp-rules §9).
- Size: no function over 30 lines; split by meaning, not by count (cpp-rules §10).
- Ownership and threads: who destroys each new member; any new thread or queue comes from the threading library and is
  bounded (cpp-rules §7, §8).
- Duplication: did the change re-implement something with a single home? (cpp-rules §12)
- Proof: a self-check for the new logic; the gate clean; the commit message says what was verified where
  (process.md).

## Reference files

- `references/cpp-rules.md` — the full rule book: layout, naming table, header-documentation template, class design,
  roles, patterns table, ownership, threading, errors, function length, efficiency, single homes, gate, tests.
- `references/process.md` — commits, clean-worktree verification, parallel work in worktrees, measuring before
  claiming a speed-up, writing docs and commit messages in plain language, how to report what was and was not verified.
- `assets/clang-format`, `assets/clang-tidy` — the configs, verbatim from the source project (see bootstrap step 2).
- `assets/self-check.cmake` — the `add_self_check(<Name> <sources> LIBS <libs>)` helper and an example check file.
- `assets/check.sh` — a generic gate script: format check, clang-tidy, cppcheck, house rules, shellcheck, ruff.
