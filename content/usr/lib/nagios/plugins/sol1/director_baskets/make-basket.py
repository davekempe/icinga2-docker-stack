from DirectorUtil import *
import json
import os
import sys
import importlib

from loguru import logger


def getMethod(script):
    if script.endswith('.py'):
        return script[:-3]
    return script

def argsClass(script, script_dir, name, prefix):
    try:
        logger.debug(script)
        module = getMethod(script)
        logger.debug(module)
        # Import the module
        check = importlib.import_module(module)
        # Import the args
        InitArgs = getattr(check, 'InitArgs')
    except Exception as e:
        logger.debug(os.getcwd())
        logger.error(f"Error importing {module} ({script}): ")

    _args = getArgparseParserArgumentsDict(InitArgs.parser)
    logger.debug(_args)
    basket = DirectorBasketCheckCommand("Check Proxmox API", command=f"{script_dir} {script}", icinga_var_prefix="proxmox_api", args=_args, id=1500)
    with open(f'director_baskets/baskets/{module}-basket.json', 'w') as _file:
        json.dump(basket.director_basket, _file, indent=4)
    logger.debug(basket.director_basket)
    sys.exit(0)



if __name__ == "__main__":
    # Init args
    parser = argparse.ArgumentParser(description="Icinga director basket generator")
    parser.add_argument('--name', type=str, help='Check script to parse', required=True)
    parser.add_argument('--prefix', type=str, help='Check script to parse')
    parser.add_argument('--script', type=str, help='Check script to parse', required=True)
    parser.add_argument('--script-dir', type=str, help='Check script installed directory', default='PluginDir +')
    
    parser.add_argument('--method', type=str, choices=['args_class'], help='Method to parse the script for argument', required=True)
    
    args = parser.parse_args()

    if args.prefix is None:
        args.prefix = args.name
    
    # Get the directory of the current script
    current_dir = os.path.dirname(os.path.abspath(__file__))

    # Get the parent directory (where foo.py is located)
    parent_dir = os.path.dirname(current_dir)
    logger.debug(parent_dir)

    # Add the parent directory to sys.path
    sys.path.append(parent_dir)

    if args.method == 'args_class':
        argsClass(args.script, script_dir=args.script_dir, name=args.name, prefix=args.prefix)
