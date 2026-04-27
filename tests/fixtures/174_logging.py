import logging
import sys

# Set up root logger with a StreamHandler pointing to stdout
root = logging.getLogger()
handler = logging.StreamHandler(sys.stdout)
handler.setLevel(logging.DEBUG)
fmt = logging.Formatter('%(levelname)s:%(name)s:%(message)s')
handler.setFormatter(fmt)
root.addHandler(handler)
root.setLevel(logging.DEBUG)

root.debug('debug message')
root.info('info message')
root.warning('warning message')
root.error('error message')
root.critical('critical message')

# Named logger inherits root's handlers
log = logging.getLogger('myapp')
log.warning('from myapp')

# Level constants
print(logging.DEBUG)
print(logging.INFO)
print(logging.WARNING)

# getLevelName in both directions
print(logging.getLevelName(10))
print(logging.getLevelName('WARNING'))
