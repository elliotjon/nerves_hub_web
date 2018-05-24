# nerveshub

[![CircleCI](https://circleci.com/gh/nerves-hub/nerveshub/tree/master.svg?style=svg)](https://circleci.com/gh/nerves-hub/nerveshub/tree/master)
[![Coverage Status](https://coveralls.io/repos/github/nerves-hub/nerveshub/badge.svg?branch=master)](https://coveralls.io/github/nerves-hub/nerveshub?branch=master)

A domain independent back end solution for rolling out software updates to edge
devices connected to IP based networking infrastructure.

## This project is not ready for general use

If you are interested in collaborating. please inquire on the `#nerves-dev`
channel on the [elixir-lang slack](https://elixir-slackin.herokuapp.com/) for
the time being.  We're in the process of building out main features and getting
the project into a form where it can be used and maintained by multiple
companies.

## Project Overview and Setup

### Language Versions

* Elixir 1.6+

### Initial App Setup

* Create directory for local data storage: `mkdir ~/db`
* Start the database (if not started): `docker-compose up -d`
* Copy `dev.env` to `.env` and customize as needed
* Run command `mix deps.get`
* Run command `make reset-db`
* Start web app: `make server` or `make iex-server` to start the server with the
  interactive shell

### Starting App

* Start the database (if not started): `docker-compose up -d`
* Start web app: `make server` or `make iex-server` to start the server with the
  interactive shell
  * The whole app will need to be compiled the first time you run this, so
    please be patient

### Client-side SSL Device Authorization

NervesHub uses Client-side SSL to authorize and identify connected devices.
Devices are required to provide a valid certificate that was signed using the
trusted certificate authority nerveshub certificate. This certificate should be
generated and kept secret and private from Internet-connected servers.

For convenience, we use the pre-generated certificates for `dev` and `test`.
Production certificates can be generated by following the SSL certificate
instructions in `test/fixtures/README.md` and setting the following environment
variables to point to the generated key and certificate paths on the server.

```text
NERVESHUB_SSL_KEY
NERVESHUB_SSL_CERT
NERVESHUB_SSL_CACERT
```

### Tags

Tags are arbitrary strings, such as `"stable"` or `"beta"`. They can be added to
Devices and Firmware.

For a Device to be considered eligible for a given Deployment, it must have
*all* the tags in the Deployment's "tags" condition.

## Simulating a Device

The `client` directory has an example OTP application that simulates a device.
It will connect to the NervesHub server via a Phoenix Channel and can be used
to exercise the server for development and test.

See `client/README.md` for more information.
