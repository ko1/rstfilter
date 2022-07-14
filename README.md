[![GH Actions](https://github.com/ko1/rstfilter/actions/workflows/ruby.yml/badge.svg)](https://github.com/ko1/rstfilter/actions/workflows/ruby.yml)

# Rstfilter

This tool prints a Ruby script with execution results.

```
$ cat sample.rb
a = 1
b = 2
c = a + b
puts "Hello" * c

$ rstfilter sample.rb -o
a = 1                                              #=> 1
b = 2                                              #=> 2
c = a + b                                          #=> 3
puts "Hello" * c                                   #=> nil
#out: HelloHelloHello
```

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'rstfilter'
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install rstfilter

## Usage

```
Usage: rstfilter [options] SCRIPT
    -c, --comment                    Show result only on comment
    -o, --output                     Show output results
    -d, --decl                       Show results on declaration
        --no-exception               Do not show exception
        --pp                         Use pp to represent objects
    -n, --nextline                   Put comments on next line
        --comment-indent=NUM         Specify comment indent size (default: 50)
        --comment-pattern=PAT        Specify comment pattern of -c (default: '#=>')
        --coment-label=LABEL         Specify comment label (default: "")
    -e, --executable=COMMAND         Execute Ruby script with given command
        --no-filename                Execute -e command without filename
    -j, --json                       Print records in JSON format
        --ignore-pragma              Ignore pragma specifiers
        --rc RCFILE                  Load RCFILE
        --verbose                    Verbose mode
```

### `-e` option

You can specify multiple `-e` options like that:

```
$ rstfilter -o sample.rb -eruby27:/home/ko1/.rbenv/versions/2.7.6/bin/ruby -e ruby30:/home/ko1/.rbenv/versions/3.0.4/bin/ruby
a = 1
#=> ruby27: 1
#=> ruby30: 1
b = 2
#=> ruby27: 2
#=> ruby30: 2
c = a + b
#=> ruby27: 3
#=> ruby30: 3
puts "Hello" * c
#=> ruby27: nil
#=> ruby30: nil
#ruby27:out: HelloHelloHello
#ruby30:out: HelloHelloHello
```

On this case, you can check results on multiple Ruby interpreters.

### Comment style options

You can write above options in the script with `#rstfilter ARGS...` comment.

```ruby
#rstfilter -c
a = 1
b = 2
c = a + b #=>
```

```
$ rstfilter sample.rb
#rstfilter -c
a = 1
b = 2
c = a + b #=> 3
```

### RC file

You can specify rcfile in YAML file.

```yaml
# rstfilter.yaml
default: -c
dir:
  '*/spec/*': -e rspec
```

rcfile accept two keys:

* `default`: set default option
* `dir`: pairs of a pattern and a option.

In this case, `deafult` option is `-c` and ` match files with the `*/spec/*` pattern applied with the given `-e rspec` option.

## Advanced demo

https://user-images.githubusercontent.com/9558/170426066-e0c19185-10e9-4932-a1ce-3088a4189b34.mp4

This video shows advanced usage to show the results with modified script immediately.

* [kv](https://rubygems.org/gems/kv) is another pager.
* `kv -w SCRIPT` monitors SCRIPT file modification and reload it immediately.
* `kv --filter-process=cmd SCRIPT` shows the result of `cmd FILE` as a filter.
* Combination: `kv -w --filter-command='rstfilter -a' SCRIPT` shows modified script with execution results.

## Implementation

With parser gem, rstfilter translates the given script and run it.

For example, the first example is translated to:

```ruby
a = ::RSTFILTER__.record(1,4,1,5){1}
b = ::RSTFILTER__.record(2,4,2,5){2}
c = ::RSTFILTER__.record(3,4,3,9){::RSTFILTER__.record(3,4,3,5){a} + ::RSTFILTER__.record(3,8,3,9){b}}
::RSTFILTER__.record(4,0,4,16){puts ::RSTFILTER__.record(4,5,4,16){::RSTFILTER__.record(4,5,4,12){"Hello"} * ::RSTFILTER__.record(4,15,4,16){c}}}
```

and `::RSTFILTER__.record` method records the results. After that, rstfilter prints the script with the results.
`--verbose` option shows the translated script and collected results.

## Contribution

Bug reports and pull requests are welcome on GitHub at https://github.com/ko1/rstfilter.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Aside

* My motivation of this tool is to make it easy to annotate the script with execution results. For example, Ruby developer's meeting generates many code like: https://github.com/ruby/dev-meeting-log/blob/master/DevMeeting-2022-05-19.md
* The name "Rst" stands for "Result". This tool is inspired from [xmpfilter](https://github.com/rcodetools/rcodetools/blob/master/lib/rcodetools/xmpfilter.rb) and original author Gotoken-san told me that "xmp" is stand for "Example" (he had wanted to make a support tool for lectures). Respect to the "xmp" mysterious word, I choosed "Rst".
