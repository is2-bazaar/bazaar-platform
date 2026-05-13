workspace "Bazaar Containers" "Vista de contenedores acotada al estado actual del codigo" {

    model {
        user = person "Usuario" "Usa la app mobile para registrarse, iniciar sesion y recuperar password. Navega catálogo y hace checkout."
        admin = person "Administrador" "Usa el backoffice para iniciar sesion administrativa."

        brevo = softwareSystem "Brevo" "Proveedor externo de email para recupero de password." {
            tags "External"
        }

        bazaar = softwareSystem "Bazaar" "Marketplace Bazaar" {

            mobile = container "App Mobile" "App React Native. Hoy integra auth real y navegación de catálogo; carrito/checkout todavía no están integrados end-to-end y el tab de carrito sigue como placeholder." "React Native + Expo" {
                tags "Mobile"
            }

            backoffice = container "Backoffice Web" "Backoffice React. Hoy tiene login y refresh reales contra el gateway; usuarios/productos tienen integración parcial, mientras órdenes y métricas administrativas siguen mockeadas." "React + Vite" {
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

            catalogService = container "Catalog Service" "Listado, detalle de productos, publicaciones y gestion de stock (Saga)." "Go" {
                tags "Service"
            }
            
            cartService = container "Cart Service" "Carrito de compras e integracion de cleanup de checkout." "Go" {
                tags "Service"
            }
            
            orderService = container "Order Service" "Orquestador central del Checkout Saga y gestion de ordenes multi-vendedor." "Go" {
                tags "Service"
            }
            
            paymentService = container "Payment Service" "Pasarela de pagos y refund." "Go" {
                tags "Service"
            }

            authDb = container "Auth DB" "Cuentas, credenciales, refresh tokens y codigos de recupero." "PostgreSQL" {
                tags "Database"
            }

            userDb = container "User DB" "Perfiles y datos propios del dominio de usuarios." "PostgreSQL" {
                tags "Database"
            }

            catalogDb = container "Catalog DB" "Productos, categorias y metadata de media. Contiene locks de stock." "PostgreSQL" {
                tags "Database"
            }
            
            cartDb = container "Cart DB" "Carrito de usuarios (Items)." "PostgreSQL" {
                tags "Database"
            }
            
            orderDb = container "Order DB" "Grupos de Checkout, Ordenes por Seller." "PostgreSQL" {
                tags "Database"
            }
            
            paymentDb = container "Payment DB" "Transacciones e intentos de pago." "PostgreSQL" {
                tags "Database"
            }
        }

        user -> mobile "Usa registro, login, checkout y compras"
        admin -> backoffice "Hace login administrativo"

        mobile -> gateway "Consume APIs" "HTTPS/JSON"
        backoffice -> gateway "Consume APIs" "HTTPS/JSON"

        gateway -> authService "Proxy de /auth/*" "HTTP/JSON síncrono"
        gateway -> userService "Publica /users/*, /profiles/* y /admin/users/*" "HTTP/JSON síncrono"
        gateway -> catalogService "Publica /catalog/*" "HTTP/JSON síncrono"
        gateway -> cartService "Publica /cart/*" "HTTP/JSON síncrono"
        gateway -> orderService "Publica /checkout*, /checkout-groups/*, /orders/*, /admin/orders/* y /seller/*" "HTTP/JSON síncrono"
        gateway -> paymentService "Publica /payments/* para consulta autenticada de pagos (user-only)" "HTTP/JSON síncrono"

        authService -> authDb "Lee y escribe"
        authService -> brevo "Envia emails de recupero" "HTTPS/API"

        userService -> userDb "Lee y escribe"
        userService -> authService "Consulta o actualiza estado de cuenta" "HTTP/JSON síncrono (X-Internal-Service-Token)"

        catalogService -> catalogDb "Lee y escribe"
        cartService -> cartDb "Lee y escribe"
        paymentService -> paymentDb "Lee y escribe"
        orderService -> orderDb "Lee y escribe"
        
        # Checkout Saga relationships
        orderService -> cartService "Consulta carrito y ejecuta cleanup idempotente" "HTTP/JSON síncrono (X-Internal-Service-Token)"
        orderService -> catalogService "Reserva, confirma o libera stock" "HTTP/JSON síncrono (X-Internal-Service-Token)"
        orderService -> paymentService "Inicia y reembolsa pagos" "HTTP/JSON síncrono (X-Internal-Service-Token)"
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
