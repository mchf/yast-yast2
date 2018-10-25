# encoding: utf-8

# ***************************************************************************
#
# Copyright (c) 2002 - 2012 Novell, Inc.
# All Rights Reserved.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of version 2 of the GNU General Public License as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.   See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, contact Novell, Inc.
#
# To contact Novell about this file by physical or electronic mail,
# you may find current contact information at www.novell.com
#
# ***************************************************************************

require "yast/core_ext"

Yast.import "UI"
Yast.import "CommandLine"
Yast.import "Directory"
Yast.import "FileUtils"
Yast.import "Label"

module Yast
  # Reads a \n separated list of filenames from
  # /var/lib/YaST2/filenames
  # Lines starting with "#" are ignored (comments)
  # A line starting with "*" is taken as the default filename, the "*" is stripped
  #
  # All files are listed in an editable combo box, where the user can
  # easily switch between files and even add a new file
  #
  # At finish, the list of filenames is written back to
  # /var/lib/YaST2/filenames
  # adapting the default line (starting with "*") accordingly.
  #
  # The default is either given as WFM::Args(0) or is the file last viewed.
  class ViewAnymsgClient < Client
    using Yast::CoreExt::AnsiString

    # [String] Default list of log files
    DEFAULT_FILENAMES = [
      "/var/log/boot.log",
      "/var/log/messages",
      "/var/log/YaST2/y2log"
    ].freeze

    def main
      textdomain "base"

      # Check if the filename list is present
      if !FileUtils.Exists(filenames_path)
        SCR.Execute(
          path(".target.bash"),
          "/bin/cp #{::File.join(Directory.ydatadir, "filenames")} #{filenames_path}"
        )
      end

      # get filename list
      @filenames = Convert.to_string(
        SCR.Read(path(".target.string"), filenames_path)
      )

      @filenames ||= ""

      # convert \n separated string to ycp list.

      @all_files = Builtins.splitstring(@filenames, "\n")
      @all_files |= DEFAULT_FILENAMES

      @set_default = false
      @combo_files = []

      # check if default given as argument

      @filename = ""
      if Ops.greater_than(Builtins.size(WFM.Args), 0) &&
          Ops.is_string?(WFM.Args(0))
        @filename = Convert.to_string(WFM.Args(0))
        if @filename != ""
          @combo_files = [Item(Id(@filename), @filename, true)]
          @set_default = true
        end
      end

      # the command line description map
      @cmdline = { "id" => "view_anymsg" }
      return CommandLine.Run(@cmdline) if @filename == "help"

      # build up ComboBox

      Builtins.foreach(@all_files) do |name|
        # empty lines or lines starting with "#" are ignored
        if name != "" && Builtins.substring(name, 0, 1) != "#"
          # the default is either given via WFM::Args() -> filename != ""
          # or by a filename starting with "*"
          if Builtins.substring(name, 0, 1) == "*"
            name = Builtins.substring(name, 1) # strip leading "*"
            if name != @filename # do not add it twice
              @combo_files = Builtins.add(
                @combo_files,
                Item(Id(name), name, !@set_default)
              )
            end
            if !@set_default
              @filename = name if @filename == ""
              @set_default = true
            end
          elsif name != @filename # do not add it twice
            @combo_files = Builtins.add(@combo_files, Item(Id(name), name))
          end
        end
      end

      if !@set_default && @filename != ""
        @all_files = Builtins.add(@all_files, Ops.add("*", @filename))
        @combo_files = Builtins.add(
          @combo_files,
          Item(Id(@filename), @filename)
        )
      end

      # set up dialogue

      UI.OpenDialog(
        Opt(:decorated, :defaultsize),
        VBox(
          HSpacing(70), # force width
          HBox(
            HSpacing(1.0),
            ComboBox(
              Id(:custom_file),
              Opt(:editable, :notify, :hstretch),
              "",
              @combo_files
            ),
            HStretch()
          ),
          VSpacing(0.3),
          VWeight(
            1,
            HBox(
              VSpacing(18), # force height
              HSpacing(0.7),
              LogView(
                Id(:log),
                "",
                3, # height
                0
              ), # number of lines to show
              HSpacing(0.7)
            )
          ),
          VSpacing(0.3),
          PushButton(Id(:ok), Label.OKButton),
          VSpacing(0.3)
        )
      )

      @go_on = true

      # wait until user clicks "OK"
      # check if ComboBox selected and change view accordingly

      while @go_on

        # read file content
        file_content = SCR.Read(path(".target.string"), @filename)

        if file_content
          # replace invalid byte sequences with Unicode "replacement character"
          file_content.scrub!("�")
          # remove ANSI color escape sequences
          file_content.remove_ansi_sequences
          # remove remaining ASCII control characters (ASCII 0-31 and 127 (DEL))
          # except new line (LF = 0xa) and carriage return (CR = 0xd)
          file_content.tr!("\u0000-\u0009\u000b\u000c\u000e-\u001f\u007f", "")
        else
          file_content = _("File not found.")
        end

        # Fill the LogView with file content
        UI.ChangeWidget(Id(:log), :Value, file_content)

        heading = Builtins.sformat(_("System Log (%1)"), @filename)
        UI.ChangeWidget(Id(:log), :Label, heading)

        # wait for user input

        @ret = Convert.to_symbol(UI.UserInput)

        # clicked "OK" -> exit

        if @ret == :ok
          @go_on = false
        elsif @ret == :cancel # close window
          UI.CloseDialog
          return true
        elsif @ret == :custom_file
          # adapt to combo box settings

          @new_file = Convert.to_string(
            UI.QueryWidget(Id(:custom_file), :Value)
          )
          @filename = @new_file if !@new_file.nil?
        else
          Builtins.y2milestone("bad UserInput (%1)", @ret)
        end
      end

      # write new list of filenames

      @new_files = []
      @set_default = false

      # re-build list to get new default correct
      Builtins.foreach(@all_files) do |file|
        if Builtins.substring(file, 0, 1) == "*"
          old_default = Builtins.substring(file, 1) # strip leading "*"
          if old_default == @filename # default unchanged
            @new_files = Builtins.add(@new_files, file)
            @set_default = true # new default
          else
            @new_files = Builtins.add(@new_files, old_default)
          end
        elsif file != ""
          if file == @filename # mark new default
            @new_files = Builtins.add(@new_files, Ops.add("*", @filename))
            @set_default = true
          else
            @new_files = Builtins.add(@new_files, file)
          end
        end
      end
      # if we don't have a default by now, it wasn't in the list before
      # so add it here.

      if !@set_default && @filename != ""
        @new_files = Builtins.add(@new_files, Ops.add("*", @filename))
      end

      @new_files = Builtins.toset(@new_files)

      # convert ycp list back to \n separated string

      @filenames = Ops.add(Builtins.mergestring(@new_files, "\n"), "\n")

      SCR.Write(
        path(".target.string"),
        filenames_path,
        @filenames
      )

      UI.CloseDialog

      true
    end

  private

    def filenames_path
      @filenames_path ||= ::File.join(Directory.vardir, "filenames")
    end
  end
end
