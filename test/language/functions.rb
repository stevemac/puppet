#!/usr/bin/env ruby

require File.dirname(__FILE__) + '/../lib/puppettest'

require 'puppet'
require 'puppet/parser/parser'
require 'puppet/network/client'
require 'puppettest'
require 'puppettest/resourcetesting'

class TestLangFunctions < Test::Unit::TestCase
    include PuppetTest::ParserTesting
    include PuppetTest::ResourceTesting
    def test_functions
        assert_nothing_raised do
            Puppet::Parser::AST::Function.new(
                :name => "fakefunction",
                :arguments => AST::ASTArray.new(
                    :children => [nameobj("avalue")]
                )
            )
        end

        assert_raise(Puppet::ParseError) do
            func = Puppet::Parser::AST::Function.new(
                :name => "fakefunction",
                :arguments => AST::ASTArray.new(
                    :children => [nameobj("avalue")]
                )
            )
            func.evaluate(mkscope)
        end

        assert_nothing_raised do
            Puppet::Parser::Functions.newfunction(:fakefunction, :type => :rvalue) do |input|
                return "output %s" % input[0]
            end
        end

        func = nil
        assert_nothing_raised do
            func = Puppet::Parser::AST::Function.new(
                :name => "fakefunction",
                :ftype => :rvalue,
                :arguments => AST::ASTArray.new(
                    :children => [nameobj("avalue")]
                )
            )
        end

        scope = mkscope
        val = nil
        assert_nothing_raised do
            val = func.evaluate(scope)
        end

        assert_equal("output avalue", val)
    end

    def test_taggedfunction
        scope = mkscope
        scope.resource.tag("yayness")

        # Make sure the ast stuff does what it's supposed to
        {"yayness" => true, "booness" => false}.each do |tag, retval|
            func = taggedobj(tag, :rvalue)

            val = nil
            assert_nothing_raised do
                val = func.evaluate(scope)
            end

            assert_equal(retval, val, "'tagged' returned %s for %s" % [val, tag])
        end

        # Now make sure we correctly get tags.
        scope.resource.tag("resourcetag")
        assert(scope.function_tagged("resourcetag"), "tagged function did not catch resource tags")
        scope.compiler.catalog.tag("configtag")
        assert(scope.function_tagged("configtag"), "tagged function did not catch catalog tags")
    end

    def test_failfunction
        func = nil
        assert_nothing_raised do
            func = Puppet::Parser::AST::Function.new(
                :name => "fail",
                :ftype => :statement,
                :arguments => AST::ASTArray.new(
                    :children => [stringobj("this is a failure"),
                        stringobj("and another")]
                )
            )
        end

        scope = mkscope
        val = nil
        assert_raise(Puppet::ParseError) do
            val = func.evaluate(scope)
        end
    end

    def test_multipletemplates
        Dir.mkdir(Puppet[:templatedir])
        onep = File.join(Puppet[:templatedir], "one")
        twop = File.join(Puppet[:templatedir], "two")

        File.open(onep, "w") do |f|
            f.puts "<%- if @one.nil? then raise '@one undefined' end -%>" +
                "template <%= @one %>"
        end

        File.open(twop, "w") do |f|
            f.puts "template <%= @two %>"
        end
        func = nil
        assert_nothing_raised do
            func = Puppet::Parser::AST::Function.new(
                :name => "template",
                :ftype => :rvalue,
                :arguments => AST::ASTArray.new(
                    :children => [stringobj("one"),
                        stringobj("two")]
                )
            )
        end
        ast = varobj("output", func)

        scope = mkscope

        # Test that our manual exception throw fails the parse
        assert_raise(Puppet::ParseError) do
            ast.evaluate(scope)
        end

        # Test that our use of an undefined instance variable does not throw
        # an exception, but only safely continues.
        scope.setvar("one", "One")
        assert_nothing_raised do
            ast.evaluate(scope)
        end

        # Ensure that we got the output we expected from that evaluation.
        assert_equal("template One\ntemplate \n", scope.lookupvar("output"),
                     "Undefined template variables do not raise exceptions")

        # Now, fill in the last variable and make sure the whole thing
        # evaluates correctly.
        scope.setvar("two", "Two")
        scope.unsetvar("output")
        assert_nothing_raised do
            ast.evaluate(scope)
        end

        assert_equal("template One\ntemplate Two\n", scope.lookupvar("output"),
            "Templates were not handled correctly")
    end

    # Now make sure we can fully qualify files, and specify just one
    def test_singletemplates
        template = tempfile()

        File.open(template, "w") do |f|
            f.puts "template <%= @yay.nil?() ? raise('yay undefined') : @yay %>"
        end

        func = nil
        assert_nothing_raised do
            func = Puppet::Parser::AST::Function.new(
                :name => "template",
                :ftype => :rvalue,
                :arguments => AST::ASTArray.new(
                    :children => [stringobj(template)]
                )
            )
        end
        ast = varobj("output", func)

        scope = mkscope
        assert_raise(Puppet::ParseError) do
            ast.evaluate(scope)
        end

        scope.setvar("yay", "this is yay")

        assert_nothing_raised do
            ast.evaluate(scope)
        end

        assert_equal("template this is yay\n", scope.lookupvar("output"),
            "Templates were not handled correctly")

    end

    # Make sure that legacy template variable access works as expected.
    def test_legacyvariables
        template = tempfile()

        File.open(template, "w") do |f|
            f.puts "template <%= deprecated %>"
        end

        func = nil
        assert_nothing_raised do
            func = Puppet::Parser::AST::Function.new(
                :name => "template",
                :ftype => :rvalue,
                :arguments => AST::ASTArray.new(
                    :children => [stringobj(template)]
                )
            )
        end
        ast = varobj("output", func)

        # Verify that we get an exception using old-style accessors.
        scope = mkscope
        assert_raise(Puppet::ParseError) do
            ast.evaluate(scope)
        end

        # Verify that we evaluate and return their value correctly.
        scope.setvar("deprecated", "deprecated value")
        assert_nothing_raised do
            ast.evaluate(scope)
        end

        assert_equal("template deprecated value\n", scope.lookupvar("output"),
                     "Deprecated template variables were not handled correctly")
    end

    # Make sure that problems with kernel method visibility still exist.
    def test_kernel_module_shadows_deprecated_var_lookup
        template = tempfile()
        File.open(template, "w").puts("<%= binding %>")

        func = nil
        assert_nothing_raised do
            func = Puppet::Parser::AST::Function.new(
                :name => "template",
                :ftype => :rvalue,
                :arguments => AST::ASTArray.new(
                    :children => [stringobj(template)]
                )
            )
        end
        ast = varobj("output", func)

        # Verify that Kernel methods still shadow deprecated variable lookups.
        scope = mkscope
        assert_nothing_raised("No exception for Kernel shadowed variable names") do
            ast.evaluate(scope)
        end
    end

    def test_tempatefunction_cannot_see_scopes
        template = tempfile()

        File.open(template, "w") do |f|
            f.puts "<%= lookupvar('myvar') %>"
        end

        func = nil
        assert_nothing_raised do
            func = Puppet::Parser::AST::Function.new(
                :name => "template",
                :ftype => :rvalue,
                :arguments => AST::ASTArray.new(
                    :children => [stringobj(template)]
                )
            )
        end
        ast = varobj("output", func)

        scope = mkscope
        scope.setvar("myvar", "this is yayness")
        assert_raise(Puppet::ParseError) do
            ast.evaluate(scope)
        end
    end

    def test_template_reparses
        template = tempfile()

        File.open(template, "w") do |f|
            f.puts "original text"
        end

        file = tempfile()

        Puppet[:code] = %{file { "#{file}": content => template("#{template}") }}
        Puppet[:environment] = "yay"
        interp = Puppet::Parser::Interpreter.new
        node = mknode
        node.stubs(:environment).returns("yay")

        Puppet[:environment] = "yay"

        catalog = nil
        assert_nothing_raised {
            catalog = interp.compile(node)
        }

        version = catalog.version

        fileobj = catalog.vertices.find { |r| r.title == file }
        assert(fileobj, "File was not in catalog")

        assert_equal("original text\n", fileobj["content"],
            "Template did not work")

        Puppet[:filetimeout] = -5
        # Have to sleep because one second is the fs's time granularity.
        sleep(1)

        # Now modify the template
        File.open(template, "w") do |f|
            f.puts "new text"
        end

        newversion = interp.compile(node).version

        assert(version != newversion, "Parse date did not change")
    end

    def test_template_defined_vars
        template = tempfile()

        File.open(template, "w") do |f|
            f.puts "template <%= @yayness %>"
        end

        func = nil
        assert_nothing_raised do
            func = Puppet::Parser::AST::Function.new(
                :name => "template",
                :ftype => :rvalue,
                :arguments => AST::ASTArray.new(
                    :children => [stringobj(template)]
                )
            )
        end
        ast = varobj("output", func)

        {
            "" => "",
            false => "false",
        }.each do |string, value|
            scope = mkscope
            scope.setvar("yayness", string)
            assert_equal(string, scope.lookupvar("yayness", false))

            assert_nothing_raised("An empty string was not a valid variable value") do
                ast.evaluate(scope)
            end

            assert_equal("template #{value}\n", scope.lookupvar("output"),
                         "%s did not get evaluated correctly" % string.inspect)
        end
    end

    def test_autoloading_functions
        assert_equal(false, Puppet::Parser::Functions.function(:autofunc),
            "Got told autofunc already exists")

        dir = tempfile()
        $: << dir
        newpath = File.join(dir, "puppet", "parser", "functions")
        FileUtils.mkdir_p(newpath)

        File.open(File.join(newpath, "autofunc.rb"), "w") { |f|
            f.puts %{
                Puppet::Parser::Functions.newfunction(:autofunc, :type => :rvalue) do |vals|
                    Puppet.wanring vals.inspect
                end
            }
        }

        obj = nil
        assert_nothing_raised {
            obj = Puppet::Parser::Functions.function(:autofunc)
        }

        assert(obj, "Did not autoload function")
        assert(Puppet::Parser::Scope.method_defined?(:function_autofunc),
            "Did not set function correctly")
    end

    def test_realize
        scope = mkscope
        parser = scope.compiler.parser
    
        realize = Puppet::Parser::Functions.function(:realize)

        # Make a definition
        parser.newdefine("mytype")
        
        [%w{file /tmp/virtual}, %w{mytype yay}].each do |type, title|
            # Make a virtual resource
            virtual = mkresource(:type => type, :title => title,
                :virtual => true, :params => {}, :scope => scope)
        
            scope.compiler.add_resource(scope, virtual)

            ref = Puppet::Parser::Resource::Reference.new(
                :type => type, :title => title,
                :scope => scope
            )
            # Now call the realize function
            assert_nothing_raised do
                scope.function_realize(ref)
            end

            # Make sure it created a collection
            assert_equal(1, scope.compiler.collections.length,
                "Did not set collection")

            assert_nothing_raised do
                scope.compiler.collections.each do |coll| coll.evaluate end
            end
            scope.compiler.collections.clear

            # Now make sure the virtual resource is no longer virtual
            assert(! virtual.virtual?, "Did not make virtual resource real")
        end

        # Make sure we puke on any resource that doesn't exist
        none = Puppet::Parser::Resource::Reference.new(
            :type => "file", :title => "/tmp/nosuchfile",
            :scope => scope
        )

        # The function works
        assert_nothing_raised do
            scope.function_realize(none.to_s)
        end

        # Make sure it created a collection
        assert_equal(1, scope.compiler.collections.length,
            "Did not set collection")

        # And the collection has our resource in it
        assert_equal([none.to_s], scope.compiler.collections[0].resources,
            "Did not set resources in collection")
    end
    
    def test_defined
        scope = mkscope
        parser = scope.compiler.parser

        defined = Puppet::Parser::Functions.function(:defined)
        
        parser.newclass("yayness")
        parser.newdefine("rahness")
        
        assert_nothing_raised do
            assert(scope.function_defined("yayness"), "yayness class was not considered defined")
            assert(scope.function_defined("rahness"), "rahness definition was not considered defined")
            assert(scope.function_defined("service"), "service type was not considered defined")
            assert(! scope.function_defined("fakness"), "fakeness was considered defined")
        end
        
        # Now make sure any match in a list will work
        assert(scope.function_defined(["booness", "yayness", "fakeness"]),
            "A single answer was not sufficient to return true")
        
        # and make sure multiple falses are still false
        assert(! scope.function_defined(%w{no otherno stillno}),
            "Multiple falses were somehow true")
        
        # Now make sure we can test resources
        scope.compiler.add_resource(scope, mkresource(:type => "file", :title => "/tmp/rahness",
            :scope => scope, :source => scope.source,
            :params => {:owner => "root"}))
        
        yep = Puppet::Parser::Resource::Reference.new(:type => "file", :title => "/tmp/rahness")
        nope = Puppet::Parser::Resource::Reference.new(:type => "file", :title => "/tmp/fooness")
        
        assert(scope.function_defined([yep]), "valid resource was not considered defined")
        assert(! scope.function_defined([nope]), "invalid resource was considered defined")
    end

    def test_search
        parser = mkparser
        scope = mkscope(:parser => parser)
        
        fun = parser.newdefine("yay::ness")
        foo = parser.newdefine("foo::bar")

        search = Puppet::Parser::Functions.function(:search)
        assert_nothing_raised do
            scope.function_search(["foo", "yay"])
        end

        ffun = ffoo = nil
        assert_nothing_raised("Search path change did not work") do
            ffun = scope.finddefine("ness")
            ffoo = scope.finddefine('bar')
        end

        assert(ffun, "Could not find definition in 'fun' namespace")
        assert(ffoo, "Could not find definition in 'foo' namespace")
    end

    def test_include
        scope = mkscope
        parser = scope.compiler.parser

        include = Puppet::Parser::Functions.function(:include)

        assert_raise(Puppet::ParseError, "did not throw error on missing class") do
            scope.function_include("nosuchclass")
        end

        parser.newclass("myclass")

        scope.compiler.expects(:evaluate_classes).with(%w{myclass otherclass}, scope, false).returns(%w{myclass otherclass})

        assert_nothing_raised do
            scope.function_include(["myclass", "otherclass"])
        end
    end

    def test_file
        parser = mkparser
        scope = mkscope(:parser => parser)

        file = Puppet::Parser::Functions.function(:file)

        file1 = tempfile
        file2 = tempfile
        file3 = tempfile

        File.open(file2, "w") { |f| f.puts "yaytest" }

        val = nil
        assert_nothing_raised("Failed to call file with one arg") do
            val = scope.function_file([file2])
        end

        assert_equal("yaytest\n", val, "file() failed")

        assert_nothing_raised("Failed to call file with two args") do
            val = scope.function_file([file1, file2])
        end

        assert_equal("yaytest\n", val, "file() failed")

        assert_raise(Puppet::ParseError, "did not fail when files are missing") do
            val = scope.function_file([file1, file3])
        end
    end

    def test_generate
        command = tempfile
        sh = %x{which sh}
        File.open(command, "w") do |f|
            f.puts %{#!#{sh}
            if [ -n "$1" ]; then
                echo "yay-$1"
            else
                echo yay
            fi
            }
        end
        File.chmod(0755, command)
        assert_equal("yay\n", %x{#{command}}, "command did not work")
        assert_equal("yay-foo\n", %x{#{command} foo}, "command did not work")

        generate = Puppet::Parser::Functions.function(:generate)

        scope = mkscope
        parser = scope.compiler.parser

        val = nil
        assert_nothing_raised("Could not call generator with no args") do
            val = scope.function_generate([command])
        end
        assert_equal("yay\n", val, "generator returned wrong results")

        assert_nothing_raised("Could not call generator with args") do
            val = scope.function_generate([command, "foo"])
        end
        assert_equal("yay-foo\n", val, "generator returned wrong results")

        assert_raise(Puppet::ParseError, "Did not fail with an unqualified path") do
            val = scope.function_generate([File.basename(command), "foo"])
        end

        assert_raise(Puppet::ParseError, "Did not fail when command failed") do
            val = scope.function_generate([%x{which touch}.chomp, "/this/dir/does/not/exist"])
        end

        fake = File.join(File.dirname(command), "..")
        dir = File.dirname(command)
        dirname = File.basename(dir)
        bad = File.join(dir, "..", dirname, File.basename(command))
        assert_raise(Puppet::ParseError, "Did not fail when command failed") do
            val = scope.function_generate([bad])
        end
    end
end

