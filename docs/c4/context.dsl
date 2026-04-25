workspace "Bazaar Context" "Vista de contexto alineada al estado actual del sistema" {

    model {
        user = person "Usuario" "Usa la app mobile para autenticarse, navegar el catalogo y gestionar su carrito."
        admin = person "Administrador" "Usa el backoffice web para autenticarse y tareas administrativas."

        brevo = softwareSystem "Brevo" "Proveedor externo de email para envio de emails transaccionales (recupero de password)." {
            tags "External"
        }

        bazaar = softwareSystem "Bazaar" "Marketplace mobile-first con backend basado en microservicios y API Gateway como punto unico de entrada." {
            tags "Core"
        }

        user -> bazaar "Usa la app mobile para autenticarse, explorar productos y gestionar su carrito"
        admin -> bazaar "Usa el backoffice web para login administrativo"

        bazaar -> brevo "Solicita envio de emails de recupero de password"
        brevo -> user "Entrega email de recupero de password"
    }

    views {
        systemContext bazaar "bazaar-system-context" "Contexto del sistema Bazaar" {
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

            element "Core" {
                background #1168bd
                color #ffffff
            }

            element "External" {
                background #777777
                color #ffffff
                border Dashed
            }
        }
    }
}