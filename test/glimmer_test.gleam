import gleeunit
import gleeunit/should
import glimmer/stream

// import gleam/io

pub fn main() {
  // let a = map_t()
  // io.debug(a)
  gleeunit.main()
}

// gleeunit test functions end in `_test`
pub fn hello_world_test() {
  1
  |> should.equal(1)
}

// test that `new` and `with` and `collect` and `write` work correctly
pub fn with_test() {
  let s = stream.new()
  {
    use <- stream.with(s)
    stream.write(s, "hi")
  }
  s
  |> stream.collect()
  |> should.equal(["hi"])
}

// test that `each` and `from_list` work correctly
pub fn each_test() {
  let input = stream.from_list([1, 2, 3, 4, 5])
  let output = stream.new()
  {
    use <- stream.with(output)
    use i <- stream.each(input)
    output
    |> stream.write(i * 2)
  }
  output
  |> stream.collect()
  |> should.equal([2, 4, 6, 8, 10])
}

// test that `try_each` works correctly
pub fn try_each_test() {
  let input = stream.from_list([2, 1, 0, -1, -2])
  let output = stream.new()
  {
    use <- stream.with(output)
    use i <- stream.try_each(input)
    case i < 0 {
      True -> Error("Found a negative!")
      False -> Ok(Nil)
    }
  }
  |> should.equal(Error("Found a negative!"))
}

pub fn map_t() {
  [1, 2, 3]
  |> stream.from_list()
  |> stream.map(fn(i) { i + 1 })
  |> stream.map(fn(i) { i * 2 })
  |> stream.collect()
  // |> should.equal([4, 6, 8])
}
