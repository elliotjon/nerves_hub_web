defmodule NervesHub.DevicesTest do
  use NervesHub.DataCase, async: false

  alias NervesHub.AuditLogs
  alias NervesHub.AuditLogs.AuditLog
  alias NervesHub.Deployments
  alias NervesHub.Devices
  alias NervesHub.Devices.CACertificate
  alias NervesHub.Devices.DeviceCertificate
  alias NervesHub.Devices.UpdatePayload
  alias NervesHub.Firmwares
  alias NervesHub.Fixtures
  alias NervesHub.Repo
  alias Ecto.Changeset

  @valid_fwup_version "1.6.0"

  setup do
    user = Fixtures.user_fixture()
    org = Fixtures.org_fixture(user)
    product = Fixtures.product_fixture(user, org)
    org_key = Fixtures.org_key_fixture(org)
    firmware = Fixtures.firmware_fixture(org_key, product)
    deployment = Fixtures.deployment_fixture(org, firmware)
    device = Fixtures.device_fixture(org, product, firmware)
    device2 = Fixtures.device_fixture(org, product, firmware)
    device3 = Fixtures.device_fixture(org, product, firmware)
    ca_fix = Fixtures.ca_certificate_fixture(org)
    %{db_cert: db_cert} = Fixtures.device_certificate_fixture(device)

    cert =
      X509.PrivateKey.new_ec(:secp256r1)
      |> X509.PublicKey.derive()
      |> X509.Certificate.new("/CN=#{device.identifier}", ca_fix.cert, ca_fix.key)

    {:ok,
     %{
       cert: cert,
       db_cert: db_cert,
       user: user,
       org: org,
       org_key: org_key,
       firmware: firmware,
       device: device,
       device2: device2,
       device3: device3,
       deployment: deployment,
       product: product
     }}
  end

  test "create_device with valid parameters", %{
    org: org,
    product: product,
    firmware: firmware
  } do
    {:ok, metadata} = Firmwares.metadata_from_firmware(firmware)

    params = %{
      org_id: org.id,
      product_id: product.id,
      firmware_metadata: metadata,
      identifier: "valid identifier"
    }

    {:ok, %Devices.Device{} = device} = Devices.create_device(params)

    for key <- Map.keys(metadata) do
      assert Map.get(device.firmware_metadata, key) == Map.get(metadata, key)
    end
  end

  test "delete_device", %{org: org, device: device} do
    {:ok, _device} = Devices.delete_device(device)

    assert {:error, _} = Devices.get_device_by_org(org, device.id)
  end

  test "can tag multiple devices", %{
    user: user,
    device: device,
    device2: device2,
    device3: device3
  } do
    devices = [device, device2, device3]
    tags = "New,Tags"

    %{ok: devices} = Devices.tag_devices(devices, user, tags)

    assert Enum.all?(devices, fn device -> device.tags == ["New", "Tags"] end)
  end

  test "can disable updates for multiple devices", %{
    user: user,
    device: device,
    device2: device2,
    device3: device3
  } do
    devices = [device, device2, device3]

    %{ok: devices} = Devices.disable_updates_for_devices(devices, user)

    assert Enum.all?(devices, fn device -> device.updates_enabled == false end)
  end

  test "can enable updates for a devices" do
    user = Fixtures.user_fixture()
    org = Fixtures.org_fixture(user, %{name: "Test-Org-2"})
    product = Fixtures.product_fixture(user, org)
    org_key = Fixtures.org_key_fixture(org)
    firmware = Fixtures.firmware_fixture(org_key, product)
    device = Fixtures.device_fixture(org, product, firmware, %{updates_enabled: false})

    {:ok, device} = Devices.update_attempted(device)
    {:ok, device} = Devices.enable_updates(device, user)

    assert device.updates_enabled
    assert device.update_attempts == []
  end

  test "can enable updates for multiple devices" do
    user = Fixtures.user_fixture()
    org = Fixtures.org_fixture(user, %{name: "Test-Org-2"})
    product = Fixtures.product_fixture(user, org)
    org_key = Fixtures.org_key_fixture(org)
    firmware = Fixtures.firmware_fixture(org_key, product)
    device = Fixtures.device_fixture(org, product, firmware, %{updates_enabled: false})
    device2 = Fixtures.device_fixture(org, product, firmware, %{updates_enabled: false})
    device3 = Fixtures.device_fixture(org, product, firmware, %{updates_enabled: false})

    devices = [device, device2, device3]

    %{ok: devices} = Devices.enable_updates_for_devices(devices, user)

    assert Enum.all?(devices, fn device -> device.updates_enabled == true end)
  end

  test "can clear penalty box for multiple devices" do
    user = Fixtures.user_fixture()
    org = Fixtures.org_fixture(user, %{name: "Test-Org-2"})
    product = Fixtures.product_fixture(user, org)
    org_key = Fixtures.org_key_fixture(org)
    firmware = Fixtures.firmware_fixture(org_key, product)
    device = Fixtures.device_fixture(org, product, firmware, %{updates_blocked_until: DateTime.utc_now()})
    device2 = Fixtures.device_fixture(org, product, firmware, %{updates_blocked_until: DateTime.utc_now()})
    device3 = Fixtures.device_fixture(org, product, firmware, %{updates_blocked_until: DateTime.utc_now()})

    devices = [device, device2, device3]

    %{ok: devices} = Devices.clear_penalty_box_for_devices(devices, user)

    assert Enum.all?(devices, fn device -> is_nil(device.updates_blocked_until) end)
  end

  test "delete_device deletes its certificates", %{
    device: device
  } do
    [_cert] = Devices.get_device_certificates(device)

    {:ok, _device} = Devices.delete_device(device)
    assert [] = Devices.get_device_certificates(device)
  end

  test "create_device with invalid parameters", %{firmware: firmware} do
    params = %{
      identifier: "valid identifier",
      architecture: firmware.architecture,
      platform: firmware.platform
    }

    assert {:error, %Changeset{}} = Devices.create_device(params)
  end

  test "cannot create two devices with the same identifier", %{
    org: org,
    product: product,
    firmware: firmware
  } do
    {:ok, metadata} = Firmwares.metadata_from_firmware(firmware)

    params = %{
      org_id: org.id,
      product_id: product.id,
      firmware_metadata: metadata,
      identifier: "valid identifier"
    }

    assert {:ok, %Devices.Device{}} = Devices.create_device(params)
    assert {:error, %Ecto.Changeset{}} = Devices.create_device(params)
  end

  test "create device certificate", %{device: device, cert: cert} do
    now = DateTime.utc_now()
    device_id = device.id

    params = %{
      serial: "12345",
      not_before: now,
      not_after: now,
      device_id: device_id,
      aki: "1234",
      ski: "5678",
      der: X509.Certificate.to_der(cert)
    }

    assert {:ok, %DeviceCertificate{device_id: ^device_id}} =
             Devices.create_device_certificate(device, params)
  end

  test "create device certificate without subject key id", %{device: device, cert: cert} do
    now = DateTime.utc_now()
    device_id = device.id

    params = %{
      serial: "12345",
      not_before: now,
      not_after: now,
      device_id: device_id,
      aki: "1234",
      der: X509.Certificate.to_der(cert)
    }

    assert {:ok, %DeviceCertificate{device_id: ^device_id}} =
             Devices.create_device_certificate(device, params)
  end

  test "select one device when it has two certificates", %{
    device: device,
    db_cert: db_cert,
    cert: cert
  } do
    now = DateTime.utc_now()

    params = %{
      serial: "67890",
      not_before: now,
      not_after: now,
      aki: "1234",
      ski: "5678",
      der: X509.Certificate.to_der(cert)
    }

    expected_id = device.id

    assert {:ok, %DeviceCertificate{} = db_cert2} =
             Devices.create_device_certificate(device, params)

    assert {:ok, %{id: ^expected_id}} = Devices.get_device_by_certificate(db_cert2)
    assert {:ok, %{id: ^expected_id}} = Devices.get_device_by_certificate(db_cert)
  end

  test "cannot create device certificates with duplicate serial numbers", %{
    device: device,
    cert: cert
  } do
    now = DateTime.utc_now()

    params = %{
      serial: "12345",
      not_before: now,
      not_after: now,
      device_id: device.id,
      aki: "1234",
      ski: "5678",
      der: X509.Certificate.to_der(cert)
    }

    assert {:ok, %DeviceCertificate{}} = Devices.create_device_certificate(device, params)
    assert {:error, %Changeset{}} = Devices.create_device_certificate(device, params)
  end

  test "cannot create device certificates with invalid parameters", %{device: device} do
    params = %{
      serial: "12345",
      device_id: device.id
    }

    assert {:error, %Changeset{}} = Devices.create_device_certificate(device, params)
  end

  test "create ca certificate with valid params", %{org: org} do
    org_id = org.id

    ca_key = X509.PrivateKey.new_ec(:secp256r1)
    ca = X509.Certificate.self_signed(ca_key, "CN=#{org.name}", template: :root_ca)

    {not_before, not_after} = NervesHub.Certificate.get_validity(ca)

    params = %{
      serial: NervesHub.Certificate.get_serial_number(ca),
      aki: NervesHub.Certificate.get_aki(ca),
      ski: NervesHub.Certificate.get_ski(ca),
      not_before: not_before,
      not_after: not_after,
      der: X509.Certificate.to_der(ca)
    }

    assert {:ok, %CACertificate{org_id: ^org_id}} = Devices.create_ca_certificate(org, params)
  end

  test "cannot create ca certificates with duplicate serial numbers", %{org: org} do
    org_id = org.id

    ca_key = X509.PrivateKey.new_ec(:secp256r1)
    ca = X509.Certificate.self_signed(ca_key, "CN=#{org.name}", template: :root_ca)

    {not_before, not_after} = NervesHub.Certificate.get_validity(ca)

    params = %{
      serial: NervesHub.Certificate.get_serial_number(ca),
      aki: NervesHub.Certificate.get_aki(ca),
      ski: NervesHub.Certificate.get_ski(ca),
      not_before: not_before,
      not_after: not_after,
      der: X509.Certificate.to_der(ca)
    }

    assert {:ok, %CACertificate{org_id: ^org_id}} = Devices.create_ca_certificate(org, params)
    assert {:error, %Changeset{}} = Devices.create_ca_certificate(org, params)
  end

  test "can get certificate by aki", %{org: org} do
    org_id = org.id

    ca_key = X509.PrivateKey.new_ec(:secp256r1)
    ca = X509.Certificate.self_signed(ca_key, "CN=#{org.name}", template: :root_ca)

    {not_before, not_after} = NervesHub.Certificate.get_validity(ca)

    serial = NervesHub.Certificate.get_serial_number(ca)
    aki = NervesHub.Certificate.get_aki(ca)

    params = %{
      serial: serial,
      aki: aki,
      ski: NervesHub.Certificate.get_ski(ca),
      not_before: not_before,
      not_after: not_after,
      der: X509.Certificate.to_der(ca)
    }

    assert {:ok, %CACertificate{org_id: ^org_id}} = Devices.create_ca_certificate(org, params)
    assert {:ok, %CACertificate{serial: ^serial}} = Devices.get_ca_certificate_by_aki(aki)
  end

  test "get_device_by_identifier with existing device", %{org: org, device: target_device} do
    assert {:ok, result} = Devices.get_device_by_identifier(org, target_device.identifier)

    for key <- [:org_id, :deployment_id, :device_identifier] do
      assert Map.get(target_device, key) == Map.get(result, key)
    end
  end

  test "get_device_by_identifier without existing device", %{org: org} do
    assert {:error, :not_found} = Devices.get_device_by_identifier(org, "non existing identifier")
  end

  test "get_eligible_deployments returns proper deployments", %{
    org: org,
    org_key: org_key,
    firmware: firmware,
    product: product
  } do
    device =
      Fixtures.device_fixture(org, product, firmware, %{
        identifier: "new identifier",
        tags: ["beta", "beta-edge"]
      })

    new_firmware = Fixtures.firmware_fixture(org_key, product, %{version: "1.0.1"})
    Fixtures.firmware_delta_fixture(firmware, new_firmware)

    params = %{
      org_id: org.id,
      firmware_id: new_firmware.id,
      name: "my deployment",
      conditions: %{
        "version" => "< 1.0.1",
        "tags" => ["beta", "beta-edge"]
      },
      is_active: false
    }

    {:ok, deployment} =
      Deployments.create_deployment(params)
      |> elem(1)
      |> Deployments.update_deployment(%{is_active: true})

    {:ok, device_with_firmware} = Devices.get_device_by_org(org, device.id)

    [%Deployments.Deployment{id: dep_id} | _] =
      Devices.get_eligible_deployments(device_with_firmware)

    assert dep_id == deployment.id
  end

  test "get_eligible_deployment does not return incorrect devices", %{
    org: org,
    org_key: org_key,
    firmware: firmware,
    product: product
  } do
    incorrect_params = [
      {%{version: "1.0.0"}, %{identifier: "foo"}},
      {%{}, %{identifier: "foobar", tags: ["beta"]}},
      {%{}, %{identifier: "foobarbaz", architecture: "foo"}},
      {%{}, %{identifier: "foobarbazbang", platform: "foo"}}
    ]

    for {f_params, d_params} <- incorrect_params do
      device = Fixtures.device_fixture(org, product, firmware, d_params)
      new_firmware = Fixtures.firmware_fixture(org_key, product, f_params)

      params = %{
        org_id: org.id,
        firmware_id: new_firmware.id,
        name: "my deployment #{d_params.identifier}",
        conditions: %{
          "version" => "< 1.0.0",
          "tags" => ["beta", "beta-edge"]
        },
        is_active: false
      }

      {:ok, _deployment} =
        Deployments.create_deployment(params)
        |> elem(1)
        |> Deployments.update_deployment(%{is_active: true})

      {:ok, device_with_firmware} = Devices.get_device_by_org(org, device.id)

      assert [] == Devices.get_eligible_deployments(device_with_firmware)
    end
  end

  test "deployments limit deploying by product", %{
    user: user,
    org: org,
    org_key: org_key,
    firmware: firmware,
    product: product
  } do
    old_deployment =
      Fixtures.deployment_fixture(org, firmware, %{
        name: "a different name",
        conditions: %{"tags" => ["beta", "beta-edge"], "version" => ""}
      })

    firmware1 = Fixtures.firmware_fixture(org_key, product, %{version: "2.0.0"})

    Deployments.update_deployment(old_deployment, %{firmware_id: firmware1.id, is_active: true})

    device =
      Fixtures.device_fixture(org, product, firmware, %{
        identifier: "new identifier",
        tags: ["beta", "beta-edge"]
      })

    product2 = Fixtures.product_fixture(user, org, %{name: "other product"})
    firmware2 = Fixtures.firmware_fixture(org_key, product2)

    params = %{
      org_id: org.id,
      firmware_id: firmware2.id,
      name: "my deployment",
      conditions: %{
        "version" => "",
        "tags" => ["beta", "beta-edge"]
      },
      is_active: false
    }

    {:ok, _deployment2} =
      Deployments.create_deployment(params)
      |> elem(1)
      |> Deployments.update_deployment(%{is_active: true})

    {:ok, device_with_firmware} = Devices.get_device_by_org(org, device.id)

    deployments =
      Devices.get_eligible_deployments(device_with_firmware)
      |> NervesHub.Repo.preload(:firmware)

    assert length(deployments) == 1

    for deployment <- deployments do
      assert deployment.firmware.product_id == product.id
    end
  end

  describe "send_update_message" do
    test "does not send when device needs attention", %{deployment: deployment, device: device} do
      assert Devices.send_update_message(%{device | updates_enabled: false}, deployment) ==
               %UpdatePayload{update_available: false}
    end

    test "does not send when deployment needs attention", %{
      deployment: deployment,
      device: device
    } do
      assert Devices.send_update_message(device, %{deployment | healthy: false}) ==
               %UpdatePayload{update_available: false}
    end

    test "does not send when firmware_meta is not present", %{
      deployment: deployment,
      device: device
    } do
      assert Devices.send_update_message(%{device | firmware_metadata: nil}, deployment) ==
               %UpdatePayload{update_available: false}
    end

    test "does not send when deployment version mismatch", %{
      deployment: deployment,
      device: device
    } do
      conditions = %{deployment.conditions | "version" => "> 1.0.0"}

      assert Devices.send_update_message(device, %{deployment | conditions: conditions}) ==
               %UpdatePayload{update_available: false}
    end

    test "does not send when deployment tags mismatch", %{deployment: deployment, device: device} do
      conditions = %{deployment.conditions | "tags" => ["wat?!"]}

      assert Devices.send_update_message(device, %{deployment | conditions: conditions}) ==
               %UpdatePayload{update_available: false}
    end

    test "broadcasts update message", %{
      deployment: deployment,
      device: device,
      firmware: firmware
    } do
      require Phoenix.ChannelTest
      Phoenix.PubSub.subscribe(NervesHub.PubSub, "device:#{device.id}")

      deployment =
        %{deployment | conditions: %{"tags" => device.tags, "version" => "< 2.0.0"}}
        # preload so that we can correctly match
        |> Repo.preload(:firmware)

      Fixtures.firmware_delta_fixture(firmware, deployment.firmware)

      assert %UpdatePayload{update_available: true} =
               Devices.send_update_message(device, deployment)

      deployment_id = deployment.id

      Phoenix.ChannelTest.assert_broadcast(
        "update",
        %{
          deployment: ^deployment,
          deployment_id: ^deployment_id,
          firmware_url: _,
          firmware_meta: %{}
        }
      )
    end
  end

  describe "resolve_update" do
    test "no update when device needs attention", %{deployment: deployment, device: device} do
      assert Devices.resolve_update(%{device | updates_enabled: false}, deployment) == %UpdatePayload{
               update_available: false
             }
    end

    test "no update when deployment needs attention", %{deployment: deployment, device: device} do
      assert Devices.resolve_update(device, %{deployment | healthy: false}) == %UpdatePayload{
               update_available: false
             }
    end

    test "no update when firmware_meta is not present", %{deployment: deployment, device: device} do
      assert Devices.resolve_update(%{device | firmware_metadata: nil}, deployment) ==
               %UpdatePayload{
                 update_available: false
               }
    end

    test "update message when valid", %{
      deployment: deployment,
      device: device,
      firmware: firmware
    } do
      deployment = deployment |> Repo.preload(:firmware)
      Fixtures.firmware_delta_fixture(firmware, deployment.firmware)

      result = Devices.resolve_update(device, deployment)
      {:ok, meta} = Firmwares.metadata_from_firmware(firmware)
      assert result.update_available
      assert result.firmware_url =~ firmware.uuid
      assert result.firmware_meta.uuid == meta.uuid
    end

    test "update when source is not present", %{
      product: product,
      org: org,
      org_key: org_key
    } do
      source = Fixtures.firmware_fixture(org_key, product)
      target = Fixtures.firmware_fixture(org_key, product)

      deployment = Fixtures.deployment_fixture(org, target, %{name: "resolve-update"})
      device = Fixtures.device_fixture(org, product, source)
      {:ok, _source} = Firmwares.delete_firmware(source)

      {:ok, firmware_url} = Firmwares.get_firmware_url(target)

      result = Devices.resolve_update(device, deployment)
      assert result.update_available
      assert result.firmware_url == firmware_url
    end

    test "update message with delta updatable device & firmware delta", %{
      product: product,
      org: org,
      org_key: org_key
    } do
      source = Fixtures.firmware_fixture(org_key, product)
      target = Fixtures.firmware_fixture(org_key, product)

      source = Ecto.Changeset.change(source, delta_updatable: true) |> Repo.update!()
      target = Ecto.Changeset.change(target, delta_updatable: true) |> Repo.update!()

      deployment = Fixtures.deployment_fixture(org, target, %{name: "resolve-update"})
      device = Fixtures.device_fixture(org, product, source)
      {:ok, device} = Devices.update_firmware_metadata(device, %{fwup_version: "1.6.0"})
      %{firmware_metadata: %{fwup_version: fwup_version}} = device

      firmware_delta = Fixtures.firmware_delta_fixture(source, target)
      assert Devices.delta_updatable?(source, target, product, fwup_version)

      {:ok, firmware_delta_url} = Firmwares.get_firmware_url(firmware_delta)

      result = Devices.resolve_update(device, deployment)
      assert result.update_available
      assert result.firmware_url == firmware_delta_url
    end

    test "no update message with delta updatable device & no firmware delta", %{
      product: product,
      org: org,
      org_key: org_key
    } do
      source = Fixtures.firmware_fixture(org_key, product)
      target = Fixtures.firmware_fixture(org_key, product)

      source = Ecto.Changeset.change(source, delta_updatable: true) |> Repo.update!()
      target = Ecto.Changeset.change(target, delta_updatable: true) |> Repo.update!()

      deployment = Fixtures.deployment_fixture(org, target, %{name: "resolve-update"})
      device = Fixtures.device_fixture(org, product, source)
      {:ok, device} = Devices.update_firmware_metadata(device, %{fwup_version: "1.6.0"})
      %{firmware_metadata: %{fwup_version: fwup_version}} = device

      assert Devices.delta_updatable?(source, target, product, fwup_version)

      result = Devices.resolve_update(device, deployment)
      refute result.update_available
    end

    test "update message with non-delta-updatable device", %{
      product: product,
      org: org,
      org_key: org_key
    } do
      source = Fixtures.firmware_fixture(org_key, product)
      target = Fixtures.firmware_fixture(org_key, product)

      deployment = Fixtures.deployment_fixture(org, target, %{name: "resolve-update"})
      device = Fixtures.device_fixture(org, product, source)

      {:ok, target_url} = Firmwares.get_firmware_url(target)

      result = Devices.resolve_update(device, deployment)
      assert result.update_available
      assert result.firmware_url == target_url
    end
  end

  test "device_connected adds audit log", %{device: device} do
    assert AuditLogs.logs_for(device) == []
    Devices.device_connected(device)
    assert [%AuditLog{description: desc}] = AuditLogs.logs_for(device)
    assert desc =~ "device #{device.identifier} connected to the server"
  end

  test "delta_updatable?", %{
    firmware: source,
    product: product,
    deployment: deployment
  } do
    fwup_version = @valid_fwup_version
    %{firmware: target} = Repo.preload(deployment, :firmware)

    assert Devices.delta_updatable?(source, target, product, fwup_version) == false

    source = Ecto.Changeset.change(source, delta_updatable: true) |> Repo.update!()
    target = Ecto.Changeset.change(target, delta_updatable: true) |> Repo.update!()

    assert product.delta_updatable == true
    assert source.delta_updatable == true
    assert target.delta_updatable == true

    assert Devices.delta_updatable?(source, target, product, fwup_version) == true

    # case where the source firmware does not exist
    assert Devices.delta_updatable?(nil, target, product, fwup_version) == false
  end

  test "matches_deployment? works when device and/or deployment tags are nil", %{
    deployment: deployment,
    device: device
  } do
    # There is a verion check before the tags, so load both versions
    # here to ensure they match and we get to the tag check
    device = put_in(device.firmware_metadata.version, "1.0.0")
    deployment = put_in(deployment.conditions["version"], "1.0.0")

    nil_tags_deployment = put_in(deployment.conditions["tags"], nil)

    refute Devices.matches_deployment?(%{device | tags: nil}, deployment)
    assert Devices.matches_deployment?(%{device | tags: nil}, nil_tags_deployment)
    assert Devices.matches_deployment?(device, nil_tags_deployment)
  end

  describe "tracking update attempts and verifying eligibility" do
    test "records the timestamp of an attempt", %{device: device} do
      {:ok, device} = Devices.update_attempted(device)
      assert Enum.count(device.update_attempts) == 1

      {:ok, device} = Devices.update_attempted(device)
      assert Enum.count(device.update_attempts) == 2
    end

    test "records and audit log for updating", %{device: device} do
      assert [] = AuditLogs.logs_for(device)

      {:ok, device} = Devices.update_attempted(device)

      [audit_log] = AuditLogs.logs_for(device)

      assert audit_log.description =~ ~r/attempting to update/
    end

    test "resets update attempts on successful update", %{device: device} do
      {:ok, device} = Devices.update_attempted(device)
      assert Enum.count(device.update_attempts) == 1

      {:ok, device} = Devices.firmware_update_successful(device)
      assert Enum.count(device.update_attempts) == 0
    end

    test "device updates successfully", %{device: device, deployment: deployment} do
      {:ok, device} = Devices.update_attempted(device)

      {:ok, device} = Devices.verify_update_eligibility(device, deployment)

      assert device.updates_enabled
      refute device.updates_blocked_until
    end

    test "device updates successfully after a few attempts", %{
      device: device,
      deployment: deployment
    } do
      {:ok, device} = Devices.update_attempted(device)
      {:ok, device} = Devices.update_attempted(device)

      {:ok, device} = Devices.verify_update_eligibility(device, deployment)

      assert device.updates_enabled
      refute device.updates_blocked_until
    end

    test "device updates successfully after a few attempts over a long period of time", state do
      %{device: device, deployment: deployment} = state
      deployment = %{deployment | device_failure_threshold: 6, device_failure_rate_amount: 3}

      now = DateTime.utc_now()

      {:ok, device} = Devices.update_attempted(device, DateTime.add(now, -3600, :second))
      {:ok, device} = Devices.update_attempted(device, DateTime.add(now, -1200, :second))
      {:ok, device} = Devices.update_attempted(device, now)

      {:ok, device} = Devices.verify_update_eligibility(device, deployment)

      assert device.updates_enabled
      refute device.updates_blocked_until
    end

    test "device is unhealthy and should be put in the penalty box based on total attemps", state do
      %{device: device, deployment: deployment} = state
      deployment = Repo.preload(deployment, [:firmware])
      deployment = %{deployment | device_failure_threshold: 6}

      now = DateTime.utc_now()

      {:ok, device} = Devices.update_attempted(device, DateTime.add(now, -3600, :second))
      {:ok, device} = Devices.update_attempted(device, DateTime.add(now, -1200, :second))
      {:ok, device} = Devices.update_attempted(device, DateTime.add(now, -500, :second))
      {:ok, device} = Devices.update_attempted(device, DateTime.add(now, -500, :second))
      {:ok, device} = Devices.update_attempted(device, DateTime.add(now, -500, :second))
      {:ok, device} = Devices.update_attempted(device, now)

      {:error, :updates_blocked, device} = Devices.verify_update_eligibility(device, deployment)

      assert device.updates_blocked_until
    end

    test "device is unhealthy and should be put in the penalty box based on attempt rate", state do
      %{device: device, deployment: deployment} = state
      deployment = Repo.preload(deployment, [:firmware])

      now = DateTime.utc_now()

      {:ok, device} = Devices.update_attempted(device, DateTime.add(now, -13, :second))
      {:ok, device} = Devices.update_attempted(device, DateTime.add(now, -10, :second))
      {:ok, device} = Devices.update_attempted(device, DateTime.add(now, -5, :second))
      {:ok, device} = Devices.update_attempted(device, DateTime.add(now, -2, :second))
      {:ok, device} = Devices.update_attempted(device, now)

      {:error, :updates_blocked, device} = Devices.verify_update_eligibility(device, deployment)

      assert device.updates_blocked_until
    end

    test "device is in the penalty box and should be rejected for updates", state do
      %{device: device, deployment: deployment} = state
      deployment = Repo.preload(deployment, [:firmware])
      now = DateTime.utc_now()

      # future time
      device = %{device | updates_blocked_until: DateTime.add(now, 1, :second)}
      {:error, :updates_blocked, _device} = Devices.verify_update_eligibility(device, deployment, now)

      # now
      device = %{device | updates_blocked_until: now}
      {:ok, _device} = Devices.verify_update_eligibility(device, deployment, now)

      # past time
      device = %{device | updates_blocked_until: DateTime.add(now, -1, :second)}
      {:ok, _device} = Devices.verify_update_eligibility(device, deployment, now)
    end
  end
end