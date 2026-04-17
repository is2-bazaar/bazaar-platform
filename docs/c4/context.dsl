workspace "Bazaar Context" "Vista de contexto acotada al estado actual del codigo" {

    model {
        user = person "Usuario" "Usa la app mobile para registrarse, iniciar sesion y recuperar password."
        admin = person "Administrador" "Usa el backoffice para iniciar sesion administrativa."

        brevo = softwareSystem "Brevo" "Proveedor externo de email para recupero de password." {
            tags "External"
        }

        bazaar = softwareSystem "Bazaar" "Marketplace con app mobile, backoffice y backend expuesto mediante API Gateway." {
            tags "Core"
        }

        user -> bazaar "Usa la app mobile para autenticarse y navegar la plataforma"
        admin -> bazaar "Usa el backoffice para autenticarse como administrador"
        bazaar -> brevo "Envia emails de recupero de password"
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
