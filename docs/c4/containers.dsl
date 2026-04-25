workspace "Bazaar Containers" "Vista de contenedores alineada al estado actual del codigo (auth + user + catalog + cart)" {

    model {
        user = person "Usuario" "Usa la app mobile para registrarse, iniciar sesion, navegar catalogo y gestionar su carrito."
        admin = person "Administrador" "Usa el backoffice para iniciar sesion administrativa."

        brevo = softwareSystem "Brevo" "Proveedor externo de email para recupero de password." {
            tags "External"
        }

        bazaar = softwareSystem "Bazaar" "Marketplace Bazaar" {

            mobile = container "App Mobile" "App React Native. Integra auth real contra gateway, consumo de catalogo y gestion de carrito." "React Native + Expo" {
                tags "Mobile"
            }

            backoffice = container "Backoffice Web" "Backoffice React. Login y refresh reales; vistas operativas aun mockeadas." "React + Vite" {
                tags "WebApp"
            }

            gateway = container "API Gateway" "Punto unico de entrada. Hace routing, validacion de JWT emitidos por auth-service, CORS y rate limiting de borde." "Go" {
                tags "Gateway"
            }

            authService = container "Auth Service" "Registro, login, refresh, change-password, forgot-password y reset-password. Emite JWT." "Go" {
                tags "Service"
            }

            userService = container "User Service" "Perfil privado, perfil publico y administracion basica de usuarios." "Go" {
                tags "Service"
            }

            catalogService = container "Catalog Service" "Listado y detalle de productos consumidos por mobile. Publicaciones de vendedor parcialmente disponibles." "Go" {
                tags "Service"
            }

            cartService = container "Cart Service" "Gestion de carrito persistente: agregar items, actualizar cantidades y eliminar productos." "Go" {
                tags "Service"
            }

            authDb = container "Auth DB" "Cuentas, credenciales, refresh tokens y codigos de recupero. Source of truth de autenticacion." "PostgreSQL" {
                tags "Database"
            }

            userDb = container "User DB" "Perfiles y datos del dominio de usuario. Source of truth de identidad de negocio." "PostgreSQL" {
                tags "Database"
            }

            catalogDb = container "Catalog DB" "Productos, categorias y metadata. Source of truth de catalogo." "PostgreSQL" {
                tags "Database"
            }

            cartDb = container "Cart DB" "Carritos e items por usuario. Source of truth del carrito." "PostgreSQL" {
                tags "Database"
            }
        }

        user -> mobile "Usa registro, login, catalogo y carrito"
        admin -> backoffice "Hace login administrativo"

        user -> brevo "Recibe email de recupero de password"

        mobile -> gateway "Consume /auth/*, /catalog/*, /cart/*" "HTTPS/JSON"
        backoffice -> gateway "Consume /api/auth/login y /api/auth/refresh" "HTTPS/JSON"

        gateway -> authService "Proxy de /auth/*; aplica rate limiting en endpoints sensibles" "HTTP/JSON"
        gateway -> userService "Publica /users/*, /profiles/* y /admin/users/*" "HTTP/JSON"
        gateway -> catalogService "Publica /catalog/*" "HTTP/JSON"
        gateway -> cartService "Publica /cart/*" "HTTP/JSON"

        authService -> authDb "Lee y escribe"
        authService -> brevo "Envia emails de recupero" "HTTPS/API"

        userService -> userDb "Lee y escribe"
        userService -> authService "Consulta/valida estado de cuenta cuando es necesario" "HTTP/JSON"

        catalogService -> catalogDb "Lee y escribe"

        cartService -> cartDb "Lee y escribe"
        cartService -> catalogService "Consulta informacion de producto para validaciones" "HTTP/JSON"
    }

    views {
        container bazaar "bazaar-container-view" "Contenedores reales del estado actual del sistema" {
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