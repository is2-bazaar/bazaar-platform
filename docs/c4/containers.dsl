workspace "Bazaar Containers" "Vista de contenedores acotada al estado actual del codigo" {

    model {
        user = person "Usuario" "Usa la app mobile para registrarse, iniciar sesion y recuperar password."
        admin = person "Administrador" "Usa el backoffice para iniciar sesion administrativa."

        brevo = softwareSystem "Brevo" "Proveedor externo de email para recupero de password." {
            tags "External"
        }

        bazaar = softwareSystem "Bazaar" "Marketplace Bazaar" {

            mobile = container "App Mobile" "App React Native. Hoy integra auth real contra el gateway; el resto de flujos esta parcial o mockeado." "React Native + Expo" {
                tags "Mobile"
            }

            backoffice = container "Backoffice Web" "Backoffice React. Hoy tiene login y refresh reales contra el gateway; las vistas operativas de admin siguen mockeadas." "React + Vite" {
                tags "WebApp"
            }

            gateway = container "API Gateway" "Punto unico de entrada. Hace routing, validacion de JWT, CORS y rate limiting de borde." "Go" {
                tags "Gateway"
            }

            authService = container "Auth Service" "Registro, login, refresh, change-password, forgot-password y reset-password." "Go" {
                tags "Service"
            }

            userService = container "User Service" "Perfil privado, perfil publico y administracion basica de usuarios." "Go" {
                tags "Service"
            }

            catalogService = container "Catalog Service" "Listado, detalle de productos y publicaciones del vendedor." "Go" {
                tags "Service"
            }

            authDb = container "Auth DB" "Cuentas, credenciales, refresh tokens y codigos de recupero." "PostgreSQL" {
                tags "Database"
            }

            userDb = container "User DB" "Perfiles y datos propios del dominio de usuarios." "PostgreSQL" {
                tags "Database"
            }

            catalogDb = container "Catalog DB" "Productos, categorias y metadata de media." "PostgreSQL" {
                tags "Database"
            }
        }

        user -> mobile "Usa registro, login y recupero de password"
        admin -> backoffice "Hace login administrativo"

        mobile -> gateway "Consume /auth/*" "HTTPS/JSON"
        backoffice -> gateway "Consume /api/auth/login y /api/auth/refresh" "HTTPS/JSON"

        gateway -> authService "Proxy de /auth/*; aplica rate limiting por IP en endpoints sensibles" "HTTP/JSON"
        gateway -> userService "Publica /users/*, /profiles/* y /admin/users/*" "HTTP/JSON"
        gateway -> catalogService "Publica /catalog/*" "HTTP/JSON"

        authService -> authDb "Lee y escribe"
        authService -> brevo "Envia emails de recupero" "HTTPS/API"

        userService -> userDb "Lee y escribe"
        userService -> authService "Consulta o actualiza estado de cuenta" "HTTP/JSON"

        catalogService -> catalogDb "Lee y escribe"
    }

    views {
        container bazaar "bazaar-container-view" "Contenedores reales del codigo actual" {
            include *
            autolayout lr
        }

        styles {
            element "Person" {
                shape Person
                background #0b3d91
                color #ffffff
            }

            element "Software System" {
                background #1168bd
                color #ffffff
            }

            element "External" {
                background #777777
                color #ffffff
                border Dashed
            }

            element "Container" {
                background #438dd5
                color #ffffff
            }

            element "Mobile" {
                shape MobileDevicePortrait
                background #6a1b9a
                color #ffffff
            }

            element "WebApp" {
                shape WebBrowser
                background #1565c0
                color #ffffff
            }

            element "Gateway" {
                shape Hexagon
                background #00897b
                color #ffffff
            }

            element "Service" {
                background #2e7d32
                color #ffffff
            }

            element "Database" {
                shape Cylinder
                background #455a64
                color #ffffff
            }
        }
    }
}
