import math

# Basic functions
print(math.floor(3.7))                                # 3
print(math.ceil(3.2))                                 # 4
print(math.trunc(3.9))                                # 3
print(math.trunc(-3.9))                               # -3

# Power and logarithm
print(math.sqrt(16))                                  # 4.0
print(math.pow(2, 10))                                # 1024.0
print(round(math.log(math.e), 5))                     # 1.0
print(round(math.log10(1000), 5))                     # 3.0
print(round(math.log2(8), 5))                         # 3.0

# Trigonometry
print(round(math.sin(math.pi / 2), 5))               # 1.0
print(round(math.cos(0), 5))                          # 1.0
print(round(math.tan(math.pi / 4), 5))                # 1.0

# Hyperbolic
print(round(math.sinh(0), 5))                         # 0.0
print(round(math.cosh(0), 5))                         # 1.0

# Constants
print(round(math.pi, 5))                              # 3.14159
print(round(math.e, 5))                               # 2.71828
print(math.inf > 1e308)                               # True
print(math.isnan(math.nan))                           # True
print(math.isinf(math.inf))                           # True

# gcd, lcm
print(math.gcd(12, 8))                                # 4
print(math.gcd(0, 5))                                 # 5
print(math.lcm(4, 6))                                 # 12

# factorial
print(math.factorial(5))                              # 120
print(math.factorial(0))                              # 1

# fabs
print(math.fabs(-3.14))                               # 3.14

# isclose
print(math.isclose(1.0, 1.0000001))                   # True
print(math.isclose(1.0, 1.1))                         # False

# degrees, radians
print(round(math.degrees(math.pi), 5))                # 180.0
print(round(math.radians(180), 5))                    # 3.14159

# hypot
print(round(math.hypot(3, 4), 5))                     # 5.0

# modf
int_part, frac_part = math.modf(3.7)
print(round(frac_part, 1))                            # 0.7
print(int_part)                                       # 3.0

# frexp, ldexp
m, e = math.frexp(8.0)
print(m)                                              # 0.5
print(e)                                              # 4

print('done')
