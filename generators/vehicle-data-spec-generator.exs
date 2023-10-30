Mix.install([:jason])

defmodule Loader do
  @moduledoc """
  1. Clone auto-api-json-schema

     clone git@github.com:highmobility/auto-api-json-schema.git

  2. Generate spec
    elixir vehicle-data-spec-generator.exs > hm-vehicle-data-api-v1.json

  3. Convert the json file to YML!

  myconvertor hm-vehicle-data-api-v1.json > ../hm-vehicle-data-api-v1.yml
  """
  def load_json(filepath, replace_regex \\ []) do
    content = File.read!(filepath)

    replace_regex
    |> Enum.reduce(content, fn {pattern, replace}, acc -> Regex.replace(pattern, acc, replace) end)
    |> Jason.decode!()
  end

  def run do
    custom_types = load_custom_types() |> transform_custom_types()
    capabilities = load_capabilities() |> transform_capabilities()
    property_types = load_capabilities() |> transform_property_units()
    units = load_units() |> transform_units()
    swagger_spec(units, property_types, custom_types, capabilities)
  end

  def load_custom_types do
    replace_regex = [
      {~r{"#\/\$defs\/([a-z_]+)"}, "\"#/components/schemas/custom_type_\\1\""},
      {
        ~r{"/auto-api-json-schema/L13/misc/units.schema.json#/\$defs/([a-z_]+)"},
        "\"#/components/schemas/unit_\\1\""
      }
    ]

    load_json("auto-api-json-schema/L13/misc/custom_types.schema.json", replace_regex)
  end

  defp load_units do
    Loader.load_json("auto-api-json-schema/L13/misc/units.schema.json")
  end

  defp load_capabilities do
    replace_regex = [
      {~r{"#\/\$defs\/([a-z_]+)"}, "\"#/components/schemas/\\1\""},
      {~r{"/auto-api-json-schema/L13/misc/units.schema.json#/\$defs/([a-z_]+)"},
       "\"#/components/schemas/unit_\\1\""},
      {~r{"/auto-api-json-schema/L13/misc/custom_types.schema.json#/\$defs/([a-z_]+)"},
       "\"#/components/schemas/custom_type_\\1\""}
    ]

    spec_dir = "auto-api-json-schema/L13/capabilities/"

    skipped_capabilities = [
      "wi_fi",
      "valet_mode",
      "driver_fatigue",
      "trips",
      "home_charger",
      "vehicle_time",
      "mobile",
      "keyfob_position",
      "tachograph",
      "navi_destination",
      "parking_ticket"
    ]

    spec_dir
    |> File.ls!()
    |> Enum.map(fn file -> {hd(String.split(file, ".")), "#{spec_dir}#{file}"} end)
    |> Enum.reject(fn {key, _} -> key in skipped_capabilities end)
    |> Enum.map(fn {key, file} -> {key, load_json(file, replace_regex)} end)
  end

  defp transform_custom_types(spec) do
    spec["$defs"]
    |> Enum.map(fn {key, value} ->
      {"custom_type_#{key}", value}
    end)
    |> Map.new()
  end

  defp transform_units(spec) do
    spec["$defs"]
    |> Enum.map(fn {key, value} -> {"unit_" <> key, value} end)
    |> Map.new()
  end

  defp transform_capabilities(capabilities) do
    capabilities
    |> Enum.map(fn {key, value} ->
      {key, transform_properties(value["properties"])}
    end)
    |> Map.new()
  end

  defp transform_property_units(capabilities) do
    capabilities
    |> Enum.flat_map(fn {_key, value} ->
      transform_properties_detail(value["$defs"])
    end)
    |> Map.new()
  end

  defp transform_properties(properties) do
    skip_props = ["vin", "nonce"]

    properties
    |> Enum.reject(fn {key, _value} -> key in skip_props end)
    |> Map.new()
  end

  defp transform_properties_detail(defs) do
    defs
    |> Enum.map(fn {key, value} ->
      props =
        value["properties"]
        |> Enum.filter(fn {key, _} -> key not in ["availability"] end)
        |> Map.new()

      {key, put_in(value, ["properties"], props)}
    end)
    |> Map.new()
  end

  defp base_properties do
    %{
      "request_id" => %{
        "type" => "string",
        "example" => "2c85d1f9a23623ac5deeb7eecba61a5f",
        "description" => "The request tracking id. Provide request_id when facing issue"
      },
      "vin" => %{
        "type" => "string",
        "example" => "1HM62652356323000",
        "description" => "The unique Vehicle Identification Number"
      },
      "brand" => %{
        "description" => "The vehicle brand",
        "type" => "string",
        "enum" => [
          "abarth",
          "alfaromeo",
          "alpine",
          "audi",
          "bmw",
          "cadillac",
          "chevrolet",
          "chrysler",
          "citroen",
          "cupra",
          "dacia",
          "dodge",
          "ds",
          "fiat",
          "ford",
          "honda",
          "hyundai",
          "iveco",
          "jaguar",
          "jeep",
          "kia",
          "lancia",
          "land_rover",
          "lexus",
          "man",
          "mazda",
          "mercedes_benz",
          "mini",
          "mitsubishi",
          "nissan",
          "opel",
          "peugeot",
          "porsche",
          "renault",
          "sandbox",
          "seat",
          "skoda",
          "smart",
          "subaru",
          "toyota",
          "unknown",
          "volkswagen",
          "volvo_cars"
        ]
      }
    }
  end

  def swagger_spec(units, property_types, custom_types, capabilities) do
    root_properties =
      capabilities
      |> Enum.map(fn {key, _value} ->
        {"#{key}", %{"$ref" => "#/components/schemas/#{key}"}}
      end)
      |> Map.new()

    schemas = %{
      "response" => %{
        "properties" => Map.merge(base_properties(), root_properties),
        "type" => "object"
      }
    }

    capabilities =
      capabilities
      |> Enum.map(fn {key, value} ->
        {key, %{"properties" => value}}
      end)
      |> Map.new()

    schemas =
      schemas
      |> Map.merge(units)
      |> Map.merge(custom_types)
      |> Map.merge(capabilities)
      |> Map.merge(property_types)
      |> Map.merge(error_schemas())

    %{
      "components" => %{
        "schemas" => schemas,
        "securitySchemes" => %{
          "VehicleDataAuth" => %{
            "type" => "oauth2",
            "flows" => %{
              "authorizationCode" => %{
                "authorizationUrl" => "https://owner-panel.sandbox.high-mobiliy.com/oauth/new",
                "tokenUrl" => "https://api.sandbox.high-mobility.com/v1/access_token",
                "scopes" => %{
                  "vehicle:data": "all configured vehicle data"
                }
              },
              "clientCredentials" => %{
                "tokenUrl" => "https://api.sandbox.high-mobility.com/v1/access_token",
                "scopes" => %{
                  "vehicle:data" => "all all configured vehicle data"
                }
              }
            }
          }
        }
      },
      "info" => %{
        "description" =>
          "This endpoint allows you to retrieve vehicle data through a RESTful interface.\n\nAuthentication: \n * For driver flow use [OAuth2](https://docs.high-mobility.com/api-references/code-references/oauth2/reference/v1/) using `authorization_code` grant type to obtain access token.\n * For fleet flow use [OAuth2](https://docs.staging.high-mobility.net/guides/platform/oauth2-client-credentials/) using `client_credentials` grant type to obtain access token.\n\n\n\nSandbox server: `https://sandbox.api.high-mobility.com`\n\n\nProduction server: `https://api.high-mobility.com`",
        "title" => "Vehicle Data API",
        "version" => "1.0.0"
      },
      "openapi" => "3.0.3",
      "paths" => %{
        "/v1/vehicle-data/autoapi-13/{vin}" => %{
          "get" => %{
            "tags" => ["Data API"],
            "security" => [%{"VehicleDataAuth" => ["vehicle:data"]}],
            "parameters" => [
              %{
                "description" => "Vehicle Identification number",
                "in" => "path",
                "name" => "vin",
                "required" => true,
                "schema" => %{"type" => "string"}
              }
            ],
            "responses" => %{
              "200" => %{
                "content" => %{
                  "application/json" => %{
                    "schema" => %{"$ref" => "#/components/schemas/response"}
                  }
                },
                "description" => "successful operation"
              },
              "401" => %{
                "content" => %{
                  "application/json" => %{
                    "examples" => %{
                      "Consent is removed by OEM" => %{
                        "value" => %{
                          "errors" => [
                            %{
                              "detail" => "Consent is removed by OEM",
                              "title" => "Not Authorized"
                            }
                          ],
                          "request_id" => "2c85d1f9a23623ac5deeb7eecba61a5f"
                        }
                      },
                      "Invalid token" => %{
                        "value" => %{
                          "errors" => [
                            %{"detail" => "Invalid token", "title" => "Not Authorized"}
                          ],
                          "request_id" => "32c6b29a-caca-449d-9a60-e2ca21a60fe3"
                        }
                      },
                      "Invalid JWT Payload" => %{
                        "value" => %{
                          "errors" => [
                            %{"detail" => "Invalid JWT Payload", "title" => "Not Authorized"}
                          ],
                          "request_id" => "32c6b29a-caca-449d-9a60-e2ca21a60fe3"
                        }
                      },
                      "Invalid authorization header" => %{
                        "value" => %{
                          "errors" => [
                            %{
                              "detail" => "Missing or invalid authorization header",
                              "title" => "Not Authorized"
                            }
                          ],
                          "request_id" => "89c6b29a-caca-449d-9a60-e2ca21a60fe3"
                        }
                      }
                    },
                    "schema" => %{"$ref" => "#/components/schemas/response401"}
                  }
                },
                "description" => "Not Authorized"
              },
              "403" => %{
                "content" => %{
                  "application/json" => %{
                    "examples" => %{
                      "Privacy mode is active" => %{
                        "value" => %{
                          "errors" => [
                            %{
                              "detail" => "Privacy mode is active",
                              "title" => "Forbidden"
                            }
                          ],
                          "request_id" => "2c85d1f9a23623ac5deeb7eecba61a5f"
                        }
                      },
                      "No active consent" => %{
                        "value" => %{
                          "errors" => [
                            %{
                              "detail" => "No active consent for this vehicle",
                              "title" => "Forbidden"
                            }
                          ],
                          "request_id" => "5c88d1f11a23624ac6deeb8eecba62a5f"
                        }
                      }
                    },
                    "schema" => %{"$ref" => "#/components/schemas/response403"}
                  }
                },
                "description" => "Forbidden"
              },
              "422" => %{
                "content" => %{
                  "application/json" => %{
                    "schema" => %{"$ref" => "#/components/schemas/response422"}
                  }
                },
                "description" => "Unprocessable Entity"
              },
              "429" => %{
                "content" => %{
                  "application/json" => %{
                    "schema" => %{"$ref" => "#/components/schemas/response429"}
                  }
                },
                "description" => "Too Many Requests"
              },
              "500" => %{
                "content" => %{
                  "application/json" => %{
                    "schema" => %{"$ref" => "#/components/schemas/response500"}
                  }
                },
                "description" => "Internal Server Error"
              },
              "503" => %{
                "content" => %{
                  "application/json" => %{
                    "schema" => %{"$ref" => "#/components/schemas/response503"}
                  }
                },
                "description" => "Service Unavailable"
              },
              "504" => %{
                "content" => %{
                  "application/json" => %{
                    "schema" => %{"$ref" => "#/components/schemas/response504"}
                  }
                },
                "description" => "Timeout"
              }
            }
          }
        }
      },
      "servers" => [
        %{"url" => "https://sandbox.api.high-mobility.com"},
        %{"url" => "https://api.high-mobility.com"}
      ]
    }
  end

  defp error_schemas do
    %{
      "response401" => %{
        "properties" => %{
          "errors" => %{
            "items" => %{
              "properties" => %{
                "detail" => %{
                  "example" => "Failure when fetching data from OEM",
                  "type" => "string"
                },
                "title" => %{"example" => "Service Unavailable", "type" => "string"}
              },
              "type" => "object"
            },
            "type" => "array"
          },
          "request_id" => %{
            "description" => "The request tracking id. Provide request_id when facing issue",
            "type" => "string"
          }
        }
      },
      "response403" => %{
        "properties" => %{
          "errors" => %{
            "items" => %{
              "properties" => %{
                "detail" => %{
                  "type" => "string"
                },
                "title" => %{"type" => "string"}
              },
              "type" => "object"
            },
            "type" => "array"
          },
          "request_id" => %{
            "description" => "The request tracking id. Provide request_id when facing issue",
            "type" => "string"
          }
        }
      },
      "response422" => %{
        "properties" => %{
          "errors" => %{
            "items" => %{
              "properties" => %{
                "detail" => %{
                  "example" => "Vehicle data is not available yet",
                  "type" => "string"
                },
                "title" => %{"example" => "Pending", "type" => "string"}
              },
              "type" => "object"
            },
            "type" => "array"
          },
          "request_id" => %{
            "description" => "The request tracking id. Provide request_id when facing issue",
            "example" => "a8306c7c-9f57-453c-8189-d06118944770",
            "type" => "string"
          }
        }
      },
      "response429" => %{
        "properties" => %{
          "errors" => %{
            "items" => %{
              "properties" => %{
                "detail" => %{
                  "example" => "Rate limit exceeded",
                  "type" => "string"
                },
                "title" => %{"example" => "Too Many Requests", "type" => "string"}
              },
              "type" => "object"
            },
            "type" => "array"
          },
          "request_id" => %{
            "description" => "The request tracking id. Provide request_id when facing issue",
            "example" => "a8306c7c-9f57-453c-8189-d06118944770",
            "type" => "string"
          }
        }
      },
      "response500" => %{
        "properties" => %{
          "errors" => %{
            "items" => %{
              "properties" => %{
                "detail" => %{
                  "example" => "Please contact support",
                  "type" => "string"
                },
                "title" => %{
                  "example" => "Internal Server Error",
                  "type" => "string"
                }
              },
              "type" => "object"
            },
            "type" => "array"
          },
          "request_id" => %{
            "description" => "The request tracking id. Provide request_id when facing issue",
            "example" => "e4828bf1-8687-4f7b-b8c7-6c4223e2b842",
            "type" => "string"
          }
        }
      },
      "response503" => %{
        "properties" => %{
          "errors" => %{
            "items" => %{
              "properties" => %{
                "detail" => %{
                  "example" => "Failure when fetching data from OEM",
                  "type" => "string"
                },
                "title" => %{"example" => "Service Unavailable", "type" => "string"}
              },
              "type" => "object"
            },
            "type" => "array"
          },
          "request_id" => %{
            "description" => "The request tracking id. Provide request_id when facing issue",
            "example" => "e4828bf1-8687-4f7b-b8c7-6c4223e2b842",
            "type" => "string"
          }
        }
      },
      "response504" => %{
        "properties" => %{
          "errors" => %{
            "items" => %{
              "properties" => %{
                "detail" => %{
                  "example" => "OEM didn't response in the expected time",
                  "type" => "string"
                },
                "title" => %{"example" => "Timeout", "type" => "string"}
              },
              "type" => "object"
            },
            "type" => "array"
          },
          "request_id" => %{
            "description" => "The request tracking id. Provide request_id when facing issue",
            "example" => "e4828bf1-8687-4f7b-b8c7-6c4223e2b842",
            "type" => "string"
          }
        }
      }
    }
  end
end

Loader.run() |> Jason.encode!() |> IO.puts()
