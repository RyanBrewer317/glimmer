//// `glimmer/dream` is a shallow wrapper around `gleam/otp/task` for promise-like workloads.
//// Dreams are conceptually coroutines that may or may not return a value. They are simply a block of
//// code executed in parallel, with some functionality to get the return value if needed.
//// `spawn` creates a dream with no return value (hence no dream is really created, and `spawn` returns Nil).
//// `spawn_unlinked` creates a dream that may crash *without crashing the owning process*, which doesn't
//// return a value either (so again, no actual dream in the implementation). `async` creates a dream that
//// does return a value, so if it crashes then the owning process crashes too, and `async` returns a dream
//// value you can use for one of this library's various `await` functions for getting the return value later on.

import gleam/erlang/process
import gleam/otp/task
import gleam/dynamic.{Dynamic}

/// The type of dreams that return values.
pub opaque type Dream(a) {
  Dream(task.Task(a))
}

/// The errors dreams may produce, 
/// checkable with `try_await` and `try_await_with_timeout`.
pub type DreamError {
  ExitError(reason: Dynamic)
  TimeoutError
}

/// Spawn a dream that won't return a value.
/// (It simply does work and side-effects.)
/// If the dream crashes then the owning process
/// also crashes.
pub fn spawn(foo: fn() -> Nil) -> Nil {
  process.start(linked: True, running: foo)
  Nil
}

/// Spawn a dream that won't return a value.
/// (It simply does work and side-effects.)
/// If the dream crashes then the owning process
/// *doesn't* crash. The crash is completely silent.
pub fn spawn_unlinked(foo: fn() -> Nil) -> Nil {
  process.start(linked: False, running: foo)
  Nil
}

/// Spawn a dream that returns a value.
/// The value is retrieved with one of the `await` functions.
/// If the dream crashes then the owning process
/// also crashes, 
pub fn async(foo: fn() -> a) -> Dream(a) {
  Dream(task.async(foo))
}

/// Get the value of a dream, waiting until it's done working,
/// the time is up, or it crashes. Returns a value that lets you
/// distinguish between these three cases.
pub fn try_await_with_timeout(
  dream: Dream(a),
  timeout: Int,
) -> Result(a, DreamError) {
  let Dream(task) = dream
  case task.try_await(task, timeout) {
    Ok(a) -> Ok(a)
    Error(task.Timeout) -> Error(TimeoutError)
    Error(task.Exit(reason)) -> Error(ExitError(reason))
  }
}

/// A version of `try_await_with_timeout` that waits indefinitely,
/// instead of until a timeout runs out.
pub fn try_await(dream: Dream(a)) -> Result(a, DreamError) {
  let Dream(task) = dream
  case task.try_await_forever(task) {
    Ok(a) -> Ok(a)
    Error(task.Timeout) -> Error(TimeoutError)
    Error(task.Exit(reason)) -> Error(ExitError(reason))
  }
}

/// A version of `try_await_with_timeout` that assumes there wasn't an error,
/// crashing if there was.
pub fn await_with_timeout(dream: Dream(a), timeout: Int) -> a {
  let assert Ok(a) = try_await_with_timeout(dream, timeout)
  a
}

/// A version of `try_await` that assumes there wasn't an error,
/// crashing if there was. If a timeout is needed see `await_with_timeout`.
pub fn await(dream: Dream(a)) -> a {
  let assert Ok(a) = try_await(dream)
  a
}
