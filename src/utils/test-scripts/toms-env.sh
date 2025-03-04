#!/usr/bin/env bash
  
     export PH_OPS_BACKEND_SERVER_URL=https://ops.local/api/v1
     export PH_OPS_SIGNATURE_URL=https://ops.local/api/v1/util/x-signature
     export PH_VOU_BACKEND_SERVER_URL=https://ops/api/v1
     export PH_ACT_BACKEND_SERVER_URL=https://ops.local/api/v1
     export PH_OPS_BULK_CONNECTOR_URL=https://ops.local
     #export PH_OPS_BATCH_KEY=MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC07fxdEQlsvWvggBgrork401cdyZ9MqV6FF/RgX6+Om23gP/rME5sE5//OoG61KU3dEj9phcHH845TuyNEyc4Vhqxe1gzl4VIZkOj+/2qxYvCsP1Sv3twTs+fDfFv5NA1ZXqiswTlgjR2Lpf1tevFQEOzB9WYvH/Bu9kgr2AlHMPV6+b7gcJij/7W1hndiCk2ahbi7oXjjODF4yEU9yNAhopibe4zzMX+FO4eFYpUmrjS5wvv6aAanfoeIMTwhF81Gj9V3rHf4UsD3VEx773q7GPuXlZSLyiNrUCdvxITh+dW8Y9ICuCTy3bFbp1/HzoPdzkkUlzPNKLlLiV2w4EcxAgMBAAECggEAMjqHfwbFyQxlMHQfQa3xIdd6LejVcqDqfqSB0Wd/A2YfAMyCQbmHpbsKh0B+u4h191OjixX5EBuLfa9MQUKNFejHXaSq+/6rnjFenbwm0IwZKJiEWDbUfhvJ0blqhypuMktXJG6YETfb5fL1AjnJWGL6d3Y7IgYJ56QzsQhOuxZidSqw468xc4sIF0CoTeJdrSC2yDCVuVlLNifm/2SXBJD8mgc1WCz0rkJhvvpW4k5G9rRSkS5f0013ZNfsfiDXoqiKkafoYNEbk7TZQNInqSuONm/UECn5GLm6IXdXSGfm1O2Lt0Kk7uxW/3W00mIPeZD+hiOObheRm/2HoOEKiQKBgQDreVFQihXAEDviIB2s6fphvPcMw/IonE8tX565i3303ubQMDIyZmsi3apN5pqSjm1TKq1KIgY2D4vYTu6vO5x9MhEO2CCZWNwC+awrIYa32FwiT8D8eZ9g+DJ4/IwXyz1fG38RCz/eIsJ0NsS9z8RKBIbfMmM+WnXRez3Fq+cbRwKBgQDEs35qXThbbFUYo1QkO0vIo85iczu9NllRxo1nAqQkfu1oTYQQobxcGk/aZk0B02r9kt2eob8zfG+X3LadIhQ0/LalnGNKI9jWLkdW4dxi7xMU99MYc3NRXmR49xGxgOVkLzKyGMisUvkTnE5v/S1nhu5uFr3JPkWcCScLOTjVxwKBgHNWsDq3+GFkUkC3pHF/BhJ7wbLyA5pavfmmnZOavO6FhB8zjFLdkdq5IuMXcl0ZAHm9LLZkJhCy2rfwKb+RflxgerR/rrAOM24Np4RU3q0MgEyaLhg85pFT4T0bzu8UsRH14O6TSQxgkEjmTsX+j9IFl56aCryPCKi8Kgy53/CfAoGAdV2kUFLPDb3WCJ1r1zKKRW1398ZKHtwO73xJYu1wg1Y40cNuyX23pj0M6IOh7zT24dZ/5ecc7tuQukw3qgprhDJFyQtHMzWwbBuw9WZO2blM6XX1vuEkLajkykihhggi12RSG3IuSqQ3ejwJkUi/jsYz/fwTwcAmSLQtV8UM5IECgYEAh4h1EkMx3NXzVFmLsb4QLMXw8+Rnn9oG+NGObldQ+nmknUPu7iz5kl9lTJy+jWtqHlHL8ZtV1cZZSZnFxX5WQH5/lcz/UD+GqWoSlWuTU34PPTJqLKSYgkoOJQDEZVMVphLySS9tuo+K/h10lRS1r9KDm3RZASa1JnnWopBZIz4=
     export PH_PLATFORM_TENANT_ID=gorilla
     export PH_PLATFORM_TENANT_IDS=gorilla
     export PH_REGISTERING_INSTITUTION_ID=SocialInstitution
     export PH_AUTH_ENABLED=false
     export PH_OAUTH_ENABLED=false
     export PH_OAUTH_TYPE=keycloak
     export PH_OAUTH_SERVER_URL=https://paymenthub.qa.oneacrefund.org/auth
     export PH_OAUTH_REALM=paymenthub
     export PH_OAUTH_CLIENT_ID=""
     export PH_OAUTH_CLIENT_SECRET=Y2xpZW50Og==
     export PH_OAUTH_BASIC_AUTH=true
     export PH_OAUTH_BASIC_AUTH_TOKEN=Y2xpZW50Og==
     export PH_DEFAULT_LANGUAGE=en
     #export PH_SUPPORTED_LANGUAGES=en

     # #ng serve --proxy-config proxy.conf.json
     # ng serve --host localhost --port 4300

     ng serve --host 0.0.0.0  --disable-host-check
