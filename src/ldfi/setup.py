import setuptools

setuptools.setup(
    name='ldfi',
    use_scm_version=True,
    description='Lineage-driven fault injection',
    url='https://github.com/symbiont-io/detsys-testkit/src/ldfi',
    author='Stevan Andjelkovic',
    author_email='stevan.andjelkovic@symbiont.io',
    license='BSD 2-clause',
    packages=setuptools.find_packages(where='src'),
    python_requires='>=3.6',
    install_requires=['z3-solver>=4.8.9.0'],
    setup_requires=['pytest-runner'],
    tests_require=['pytest'],
    entry_points={
        'console_scripts': [
            'detsys-ldfi=ldfi:main',
        ],
    },
    classifiers=[],
)
