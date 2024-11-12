#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# The aim of this class is to allow a -J / --json argument to pass in parameters instead of or
# as well as normal arguments - including required arguments
#
# To use:
# - replace 'import argparse' with 'import lib.jsonarg as argparse'
# - Add anything extra you wish to read from the JSON as a normal argument, or an alternative name for an existing argument
# - subparsers (e.g. mode) must have a dest passed in
#
# Features:
# - use of minimal argparse methods: add_argument, add_subparsers & add_parser, parse_args as normal
# - allow required arguments to be passed in JSON instead of the normal way
# - build example JSON string help
#
# Limitations/TODO:
# - you cannot pass the head of a subparser (e.g. "mode") in the JSON, you need to pass this as an argument
#
# Note:
# - this is not a subclass of argparse, it's a wrapper, any extra argparse functions will need to be wrapped here

import argparse
import json

class ArgumentParser:

    def __init__(self, *args, **kwargs):
        if '_real_parser' in kwargs:
            real_parser = kwargs['_real_parser']
            del kwargs['_real_parser']
        else:
            real_parser = argparse.ArgumentParser(*args, **kwargs)
        if '___parent' in kwargs: # store the parent so we can pass through required + json example
            self.__parent = kwargs['___parent']
            del kwargs['___parent']
        else:
            self.__parent = None
        self._real_parser = real_parser # the underlying argparse object
        self._tree = {} # any subparsers created, key is dest, value is dict with value => argparser object
        self._example_json = {} # build a JSON example for the help output
        self._required = {} # check that required arguments are passed either in JSON or individual switches/flags

    def add_argument(self, *args, **kwargs):
        # If this argument is required, we can't pass that through to the underlying argparse
        # but we also need to keep track of it so we can enforce it ourselves in parse_args
        required = False
        if 'required' in kwargs:
            if kwargs['required']:
                required = True
                kwargs['required'] = False
                if 'help' in kwargs:
                    kwargs['help'] += (" *Required here or in --json*")
                else:
                    kwargs['help'] = "*Required here or in --json*"
        real_arg = self._real_parser.add_argument(*args, **kwargs)
        if required:
            # add to the required hash
            self._required[real_arg.dest] = real_arg

        # add this argument into the json example for the help output
        type_desc = ""
        if real_arg.type:
            type_desc = f" ({real_arg.type.__name__})"
        #TODO add help for nargs, boolean, required etc
        self._example_json[real_arg.dest] = f"<{real_arg.dest}{type_desc}>"

    def add_subparsers(self, *args, **kwargs):
        # we make our own SubParser object which intercepts the add_parser calls and makes our own ArgumentParser wrapper object
        kwargs['___parent'] = self
        if not kwargs.get('dest'):
            raise Exception("Need 'dest' as keyword argument")
        # TODO make this work as a JSON arg
        return SubParser(*args, **kwargs)

    def parse_args(self, *args, **kwargs):
        #
        # This is where the real magic happens
        #
        # parse args as normal but in addition:
        # - add the -J/--json argument automatically with a nice example in the help
        # - parse out the JSON and fill in the extra arguments
        # - enforce that the required arguments are passed in either via JSON or traditionally

        #
        # build json help
        #
        # trunk parser
        example = self._example_json
        # add in all from subparsers
        for subparser in self._tree:
            sub_options = self._tree[subparser]
            for value in sub_options:
                for field in sub_options[value]._example_json:
                    example[field] = sub_options[value]._example_json[field]
        json_example = json.dumps(example, sort_keys=True)

        # add JSON argument
        self._real_parser.add_argument('-J', '--json', required=False, type=str, help=f"It is possible to parse in arguments as a json blob in combination with the other arguments, {json_example}")

        # real parsing offloaded to real argparse
        raw_args = self._real_parser.parse_args(*args, **kwargs)

        # extract the JSON and add/overwrite values
        cooked_args = raw_args
        if cooked_args.json:
            try:
                json_args = json.loads(cooked_args.json)
                delattr(cooked_args,'json') # disallow backdoor args
                for arg in vars(cooked_args):
                    if json_args and arg in json_args:
                        setattr(cooked_args, arg, str(json_args[arg]))
            except Exception as error:
                self._real_parser.error(f"The given JSON '{cooked_args.json}' could not be parsed: {error}")


        # check required fields have been given
        required = self._required

        # check also required for subparsers
        for subparser in self._tree:
            sub_options = self._tree[subparser]
            for value in sub_options:
                if getattr(cooked_args, subparser) == value: # if this is the path we are going down, check the requireds
                    for field in sub_options[value]._required:
                        required[field] = sub_options[value]._required[field]
        missing = []
        for field in required:
            if getattr(cooked_args, field) is None:
                missing_arg = self._required[field]
                missing_flags = '/'.join(missing_arg.option_strings)
                missing_dest = missing_arg.dest
                missing.append(f"{missing_flags}({missing_dest})")

        if missing:
            self._real_parser.error(f"The following fields are required: {','.join(missing)}")

        # give the people what they want
        return cooked_args

class SubParser:
    def __init__(self, *args, **kwargs):
        self.__parent = kwargs['___parent']
        self.dest = kwargs['dest']
        del kwargs['___parent']
        self.__parent._tree[self.dest] = dict()
        self.real_subparsers = self.__parent._real_parser.add_subparsers(*args, **kwargs)

    def add_parser(self, *args, **kwargs):
        real = self.real_subparsers.add_parser(*args, **kwargs)
        kwargs['_real_parser'] = real
        kwargs['___parent'] = self.__parent

        wrapper =  ArgumentParser(*args, **kwargs)

        self.__parent._tree[self.dest][args[0]] = wrapper # store the wrapper in the tree so we can get requireds back

        return wrapper

