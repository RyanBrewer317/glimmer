//// `glimmer/stream` introduces an abstraction over `gleam/erlang/process`, called a Stream.
//// The goal of streams are to make parallelism free and easy by having it appear sequential.
//// There are both functional and imperative (effectful) functions in this library.
//// The imperative functions are most useful for getting a stream started:
//// the options for filling up a fresh stream are basically just `write` which is imperative and
//// `from_list` which is functional, and `write` will make more sense for many situations.
//// Once a stream is going, and you just need to process it, then the functional functions
//// (`map`, `filter`, `reduce`, `collect`, `to_iterator`) can be very ergonomic and sensible.
//// Note: streams masquerade as lists, but they aren't datastructures. Reading from them consumes the items,
//// which the functional functions get around by saving results in a new stream or datastructure.
//// If you want something like array-indexing then you'll need to convert the stream into an 
//// actual datastructure, perhaps with `collect`, and likely lose any concurrency benefits.

import gleam/erlang/process
import gleam/iterator
import gleam/otp/task
import glimmer/dream
import gleam/list
import gleam/io

/// the types of messages used within Glimmer, for Streams.
pub opaque type PipeMessage(a) {
  Another(val: a)
  Done
}

/// A concurrent stream of values.
/// This isn't a datastructure per se, it's all lazy.
pub type Stream(a) {
  Stream(process.Subject(PipeMessage(a)))
}

/// Construct a stream.
pub fn new() -> Stream(a) {
  Stream(process.new_subject())
}

/// Construct a stream from a list.
pub fn from_list(l: List(a)) -> Stream(a) {
  let s = new()
  task.async(fn() {
    list.map(l, fn(a) { write(s, a) })
    io.println("from_list sent everything")
    close(s)
    io.println("from_list closed")
  })
  s
}

/// Get the next value from the stream. 
/// Wait if there isn't one yet.
pub fn next(s: Stream(a)) -> Result(a, Nil) {
  next_with_timeout(s, 15 * 60 * 1000)
}

/// Get the next value from the stream.
/// Wait if it isn't there yet, giving up if the timeout runs out.
pub fn next_with_timeout(s: Stream(a), timeout: Int) -> Result(a, Nil) {
  let Stream(subject) = s
  case process.receive(subject, timeout) {
    Ok(Another(a)) -> {
      Ok(a)
    }
    Ok(Done) -> {
      Error(Nil)
    }
    Error(Nil) -> {
      Error(Nil)
    }
  }
}

/// Write a value to a stream.
/// This is an imperative, side-effectful procedure.
pub fn write(s: Stream(a), value: a) -> Nil {
  let Stream(subject) = s
  process.send(subject, Another(value))
}

/// Indicate that no more values will be sent in the stream.
/// This is optional but useful if the stream is intended to model some finite datastructure,
/// which many of these functions expect.
/// This is an imperative, side-effectful procedure.
/// See `with` for some ergonomics with `close`.
pub fn close(s: Stream(a)) -> Nil {
  let Stream(subject) = s
  process.send(subject, Done)
}

/// Represent a stream as a Gleam iterator.
/// This is a more faithful representation than a list,
/// and indeed concurrency is preserved by the produced
/// iterator!
pub fn to_iterator(s: Stream(a)) -> iterator.Iterator(a) {
  iterator.unfold(
    Nil,
    fn(_) {
      case next(s) {
        Ok(a) -> {
          iterator.Next(a, Nil)
        }
        Error(Nil) -> {
          iterator.Done
        }
      }
    },
  )
}

/// Represent a stream as a list.
/// This blocks until there's an indication that the stream is over.
/// (See `close`.) Also consider using `to_iterator` if you can.
pub fn collect(s: Stream(a)) -> List(a) {
  to_iterator(s)
  |> iterator.to_list()
}

/// Use a stream and then `close` it. 
/// This is intended for `use` syntax, for example:
/// ```gleam
/// use <- with(output_stream)
/// write(out, "hi")
/// ```
pub fn with(stream: Stream(a), f: fn() -> b) -> b {
  let out = f()
  close(stream)
  out
}

/// Perform a side-effect for each element in the stream, consuming it.
/// This effect can include writing to another stream,
/// so the elements aren't necessarily gone. For example:
/// ```gleam
/// use <- with(output_stream)
/// use i <- each(input_stream)
/// output_stream |> write(i * 2)
/// ```
pub fn each(stream: Stream(a), f: fn(a) -> Nil) -> Nil {
  case next(stream) {
    Ok(a) -> {
      f(a)
      each(stream, f)
    }
    Error(Nil) -> Nil
  }
}

/// Iterate through the elements in the stream until done or `Error`.
/// Perform some computation each time.
/// For example:
/// ```gleam
/// use i <- try_each(input_stream)
/// case i < 0 {
///   True -> Error("found a negative!")
///   False -> Ok(Nil)
/// }
/// ```
pub fn try_each(stream: Stream(a), f: fn(a) -> Result(Nil, c)) -> Result(Nil, c) {
  case next(stream) {
    Ok(a) -> {
      case f(a) {
        Ok(Nil) -> try_each(stream, f)
        Error(err) -> Error(err)
      }
    }
    Error(Nil) -> Ok(Nil)
  }
}

/// Map a function over a stream concurrently 
/// (as opposed to, say, calling `collect` and then using `list.map`).
/// Internally there is imperative dark magic but this presents
/// a pure functional interface (if `f` is pure). 
/// This makes it great for pipes. For example,
/// ```gleam
/// [1, 2, 3]
/// |> from_list()
/// |> map(fn(n) { n + 1 })
/// |> map(fn(n) { n * 2 })
/// |> collect()
/// |> io.debug() // prints [4, 6, 8]
/// ```
pub fn map(input: Stream(a), f: fn(a) -> b) -> Stream(b) {
  let output = new()
  io.println("starting map")
  dream.spawn(fn() {
    each(
      input,
      fn(a) {
        io.debug(a)
        write(output, f(a))
      },
    )
    close(output)
  })
  output
}

/// Filter elements out of a stream concurrently
/// (as opposed to, say, calling `collect` and then using `list.filter`).
/// Internally there is imperative dark magic but this presents
/// a pure functional interface (if `p` is pure).
/// This makes it great for pipes. For example,
/// ```gleam
/// [1, 2, 3]
/// |> from_list
/// |> filter(fn(n) { n % 2 == 0 })
/// |> collect()
/// |> io.debug() // prints [1, 3]
/// ```
pub fn filter(input: Stream(a), p: fn(a) -> Bool) -> Stream(a) {
  let output = new()
  task.async(fn() {
    use <- with(output)
    use a <- each(input)
    case p(a) {
      True -> write(output, a)
      False -> Nil
    }
  })
  output
}

/// Reduce (or fold) a stream to a value.
/// This is concurrent in the sense that reduction steps begin before
/// the last value arrives, and may happen in parallel.
/// However, the function won't return until all values are received, of course.
/// Internally there is imperative dark magic but this presents
/// a pure functional interface (if `f` is pure).
/// This makes it great for pipes. For example,
/// ```gleam
/// [1, 2, 3]
/// |> from_list
/// |> reduce(0, fn(a, b) { a + b })
/// |> io.debug() // prints 6
/// ```
pub fn reduce(input: Stream(a), start: b, f: fn(a, b) -> b) -> b {
  case next(input) {
    Ok(a) -> reduce(input, f(a, start), f)
    Error(Nil) -> start
  }
}

/// Generate a stream. For example:
/// ```gleam
/// fn count_down(n, yield, stop) {
///   case n == 0 {
///     True -> stop()
///     False -> {
///       yield(n)
///       count_down(n - 1, yield, stop)
///     }
///   }
/// }
/// ...
/// generator(count_down(5, _, _))
/// |> collect()
/// |> io.debug() // prints [5, 4, 3, 2, 1]
/// ```
pub fn generator(g: fn(fn(b) -> Nil, fn() -> Nil) -> Nil) -> Stream(b) {
  let output = new()
  g(fn(b) { write(output, b) }, fn() { close(output) })
  output
}

/// Consume a stream and produce two streams with the same elements.
/// This can be useful since reading from streams consumes them.
/// For example:
/// ```gleam
/// [1, 2, 3]
/// |> from_list()
/// |> duplicate()
/// |> fn(#(s1, s2)) {
///   io.debug(reduce(s1, 0, fn(a, b) {a + b}))
///   collect(s2)
/// }
/// |> io.debug()
/// ```
/// In this example, the sum is printed as well as the list itself.
pub fn duplicate(s: Stream(a)) -> #(Stream(a), Stream(a)) {
  let out1 = new()
  let out2 = new()
  dream.spawn(fn() {
    use <- with(out1)
    use <- with(out2)
    use a <- each(s)
    write(out1, a)
    write(out2, a)
  })
  #(out1, out2)
}
