#!/usr/bin/env ruby

require File.dirname(__FILE__) + '/../../spec_helper'

describe Puppet::Type.type(:tidy) do
    it "should use :lstat when stating a file" do
        tidy = Puppet::Type.type(:tidy).new :path => "/foo/bar", :age => "1d"
        stat = mock 'stat'
        File.expects(:lstat).with("/foo/bar").returns stat
        tidy.stat("/foo/bar").should == stat
    end

    [:age, :size, :path, :matches, :type, :recurse, :rmdirs].each do |param|
        it "should have a %s parameter" % param do
            Puppet::Type.type(:tidy).attrclass(param).ancestors.should be_include(Puppet::Parameter)
        end

        it "should have documentation for its %s param" % param do
            Puppet::Type.type(:tidy).attrclass(param).doc.should be_instance_of(String)
        end
    end

    describe "when validating parameter values" do
        describe "for 'recurse'" do
            before do
                @tidy = Puppet::Type.type(:tidy).new :path => "/tmp", :age => "100d"
            end

            it "should allow 'true'" do
                lambda { @tidy[:recurse] = true }.should_not raise_error
            end

            it "should allow 'false'" do
                lambda { @tidy[:recurse] = false }.should_not raise_error
            end

            it "should allow integers" do
                lambda { @tidy[:recurse] = 10 }.should_not raise_error
            end

            it "should allow string representations of integers" do
                lambda { @tidy[:recurse] = "10" }.should_not raise_error
            end

            it "should allow 'inf'" do
                lambda { @tidy[:recurse] = "inf" }.should_not raise_error
            end

            it "should not allow arbitrary values" do
                lambda { @tidy[:recurse] = "whatever" }.should raise_error
            end
        end
    end

    describe "when matching files by age" do
        convertors = {
            :second => 1,
            :minute => 60
        }

        convertors[:hour] = convertors[:minute] * 60
        convertors[:day] = convertors[:hour] * 24
        convertors[:week] = convertors[:day] * 7

        convertors.each do |unit, multiple|
            it "should consider a %s to be %s seconds" % [unit, multiple] do
                tidy = Puppet::Type.type(:tidy).new :path => "/what/ever", :age => "5%s" % unit.to_s[0..0]

                tidy[:age].should == 5 * multiple
            end
        end
    end

    describe "when matching files by size" do
        convertors = {
            :b => 0,
            :kb => 1,
            :mb => 2,
            :gb => 3
        }

        convertors.each do |unit, multiple|
            it "should consider a %s to be 1024^%s bytes" % [unit, multiple] do
                tidy = Puppet::Type.type(:tidy).new :path => "/what/ever", :size => "5%s" % unit

                total = 5
                multiple.times { total *= 1024 }
                tidy[:size].should == total
            end
        end
    end

    describe "when tidying" do
        before do
            @tidy = Puppet::Type.type(:tidy).new :path => "/what/ever"
            @stat = stub 'stat', :ftype => "directory"
            File.stubs(:lstat).with("/what/ever").returns @stat
        end

        describe "and generating files" do
            it "should set the backup on the file if backup is set on the tidy instance" do
                @tidy[:backup] = "whatever"
                Puppet::Type.type(:file).expects(:new).with { |args| args[:backup] == "whatever" }

                @tidy.mkfile("/what/ever")
            end

            it "should set the file's path to the tidy's path" do
                Puppet::Type.type(:file).expects(:new).with { |args| args[:path] == "/what/ever" }

                @tidy.mkfile("/what/ever")
            end

            it "should configure the file for deletion" do
                Puppet::Type.type(:file).expects(:new).with { |args| args[:ensure] == :absent }

                @tidy.mkfile("/what/ever")
            end

            it "should force deletion on the file" do
                Puppet::Type.type(:file).expects(:new).with { |args| args[:force] == true }

                @tidy.mkfile("/what/ever")
            end

            it "should do nothing if the targeted file does not exist" do
                File.expects(:lstat).with("/what/ever").raises Errno::ENOENT

                @tidy.generate.should == []
            end
        end

        describe "and recursion is not used" do
            it "should generate a file resource if the file should be tidied" do
                @tidy.expects(:tidy?).with("/what/ever").returns true
                file = Puppet::Type.type(:file).new(:path => "/eh")
                @tidy.expects(:mkfile).with("/what/ever").returns file

                @tidy.generate.should == [file]
            end

            it "should do nothing if the file should not be tidied" do
                @tidy.expects(:tidy?).with("/what/ever").returns false
                @tidy.expects(:mkfile).never

                @tidy.generate.should == []
            end
        end

        describe "and recursion is used" do
            before do
                @tidy[:recurse] = true
                Puppet::FileServing::Fileset.any_instance.stubs(:stat).returns mock("stat")
                @fileset = Puppet::FileServing::Fileset.new("/what/ever")
                Puppet::FileServing::Fileset.stubs(:new).returns @fileset
            end

            it "should use a Fileset for recursion" do
                Puppet::FileServing::Fileset.expects(:new).with("/what/ever", :recurse => true).returns @fileset
                @fileset.expects(:files).returns %w{. one two}
                @tidy.stubs(:tidy?).returns false

                @tidy.generate
            end

            it "should generate a file resource for every file that should be tidied but not for files that should not be tidied" do
                @fileset.expects(:files).returns %w{. one two}

                @tidy.expects(:tidy?).with("/what/ever").returns true
                @tidy.expects(:tidy?).with("/what/ever/one").returns true
                @tidy.expects(:tidy?).with("/what/ever/two").returns false

                file = Puppet::Type.type(:file).new(:path => "/eh")
                @tidy.expects(:mkfile).with("/what/ever").returns file
                @tidy.expects(:mkfile).with("/what/ever/one").returns file

                @tidy.generate
            end
        end

        describe "and determining whether a file matches provided glob patterns" do
            before do
                @tidy = Puppet::Type.type(:tidy).new :path => "/what/ever"
                @tidy[:matches] = %w{*foo* *bar*}

                @stat = mock 'stat'

                @matcher = @tidy.parameter(:matches)
            end

            it "should always convert the globs to an array" do
                @matcher.value = "*foo*"
                @matcher.value.should == %w{*foo*}
            end

            it "should return true if any pattern matches the last part of the file" do
                @matcher.value = %w{*foo* *bar*}
                @matcher.must be_tidy("/file/yaybarness", @stat)
            end

            it "should return false if no pattern matches the last part of the file" do
                @matcher.value = %w{*foo* *bar*}
                @matcher.should_not be_tidy("/file/yayness", @stat)
            end
        end

        describe "and determining whether a file is too old" do
            before do
                @tidy = Puppet::Type.type(:tidy).new :path => "/what/ever"
                @stat = stub 'stat'

                @tidy[:age] = "1s"
                @tidy[:type] = "mtime"
                @ager = @tidy.parameter(:age)
            end

            it "should use the age type specified" do
                @tidy[:type] = :ctime
                @stat.expects(:ctime).returns(Time.now)

                @ager.tidy?("/what/ever", @stat)
            end

            it "should return false if the file is more recent than the specified age" do
                @stat.expects(:mtime).returns(Time.now)

                @ager.should_not be_tidy("/what/ever", @stat)
            end

            it "should return true if the file is older than the specified age" do
                @stat.expects(:mtime).returns(Time.now - 10)

                @ager.must be_tidy("/what/ever", @stat)
            end
        end

        describe "and determining whether a file is too large" do
            before do
                @tidy = Puppet::Type.type(:tidy).new :path => "/what/ever"
                @stat = stub 'stat', :ftype => "file"

                @tidy[:size] = "1kb"
                @sizer = @tidy.parameter(:size)
            end

            it "should return false if the file is smaller than the specified size" do
                @stat.expects(:size).returns(4) # smaller than a kilobyte

                @sizer.should_not be_tidy("/what/ever", @stat)
            end

            it "should return true if the file is larger than the specified size" do
                @stat.expects(:size).returns(1500) # larger than a kilobyte

                @sizer.must be_tidy("/what/ever", @stat)
            end
        end

        describe "and determining whether a file should be tidied" do
            before do
                @tidy = Puppet::Type.type(:tidy).new :path => "/what/ever"
                @stat = stub 'stat', :ftype => "file"
                File.stubs(:lstat).with("/what/ever").returns @stat
            end

            it "should not try to recurse if the file does not exist" do
                @tidy[:recurse] = true

                File.stubs(:lstat).with("/what/ever").returns nil

                @tidy.generate.should == []
            end

            it "should not be tidied if the file does not exist" do
                File.expects(:lstat).with("/what/ever").raises Errno::ENOENT

                @tidy.should_not be_tidy("/what/ever")
            end

            it "should not be tidied if the user has no access to the file" do
                File.expects(:lstat).with("/what/ever").raises Errno::EACCES

                @tidy.should_not be_tidy("/what/ever")
            end

            it "should not be tidied if it is a directory and rmdirs is set to false" do
                stat = mock 'stat', :ftype => "directory"
                File.expects(:lstat).with("/what/ever").returns stat

                @tidy.should_not be_tidy("/what/ever")
            end

            it "should return false if it does not match any provided globs" do
                @tidy[:matches] = "globs"

                matches = @tidy.parameter(:matches)
                matches.expects(:tidy?).with("/what/ever", @stat).returns false
                @tidy.should_not be_tidy("/what/ever")
            end

            it "should return false if it does not match aging requirements" do
                @tidy[:age] = "1d"

                ager = @tidy.parameter(:age)
                ager.expects(:tidy?).with("/what/ever", @stat).returns false
                @tidy.should_not be_tidy("/what/ever")
            end

            it "should return false if it does not match size requirements" do
                @tidy[:size] = "1b"

                sizer = @tidy.parameter(:size)
                sizer.expects(:tidy?).with("/what/ever", @stat).returns false
                @tidy.should_not be_tidy("/what/ever")
            end

            it "should tidy a file if age and size are set but only size matches" do
                @tidy[:size] = "1b"
                @tidy[:age] = "1d"

                @tidy.parameter(:size).stubs(:tidy?).returns true
                @tidy.parameter(:age).stubs(:tidy?).returns false
                @tidy.should be_tidy("/what/ever")
            end

            it "should tidy a file if age and size are set but only age matches" do
                @tidy[:size] = "1b"
                @tidy[:age] = "1d"

                @tidy.parameter(:size).stubs(:tidy?).returns false
                @tidy.parameter(:age).stubs(:tidy?).returns true
                @tidy.should be_tidy("/what/ever")
            end

            it "should tidy all files if neither age nor size is set" do
                @tidy.must be_tidy("/what/ever")
            end

            it "should sort the results inversely by path length, so files are added to the catalog before their directories" do
                @tidy[:recurse] = true
                @tidy[:rmdirs] = true
                fileset = Puppet::FileServing::Fileset.new("/what/ever")
                Puppet::FileServing::Fileset.expects(:new).returns fileset
                fileset.expects(:files).returns %w{. one one/two}

                @tidy.stubs(:tidy?).returns true

                @tidy.generate.collect { |r| r[:path] }.should == %w{/what/ever/one/two /what/ever/one /what/ever}
            end
        end

        it "should configure directories to require their contained files if rmdirs is enabled, so the files will be deleted first" do
            @tidy[:recurse] = true
            @tidy[:rmdirs] = true
            fileset = mock 'fileset'
            Puppet::FileServing::Fileset.expects(:new).with("/what/ever", :recurse => true).returns fileset
            fileset.expects(:files).returns %w{. one two one/subone two/subtwo one/subone/ssone}
            @tidy.stubs(:tidy?).returns true

            result = @tidy.generate.inject({}) { |hash, res| hash[res[:path]] = res; hash }
            {
                "/what/ever" => %w{/what/ever/one /what/ever/two},
                "/what/ever/one" => ["/what/ever/one/subone"],
                "/what/ever/two" => ["/what/ever/two/subtwo"],
                "/what/ever/one/subone" => ["/what/ever/one/subone/ssone"]
            }.each do |parent, children|
                children.each do |child|
                    ref = Puppet::Resource::Reference.new(:file, child)
                    result[parent][:require].find { |req| req.to_s == ref.to_s }.should_not be_nil
                end
            end
        end
    end
end
