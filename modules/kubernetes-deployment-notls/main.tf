// ----------------------------------------------------
// Modules
// ----------------------------------------------------
module "acs" {
  source            = "github.com/byu-oit/terraform-aws-acs-info.git?ref=v4.0.0"
  vpc_vpn_to_campus = true
}
// ----------------------------------------------------
// Variables
// ----------------------------------------------------
/*
data "aws_ssm_parameter" "acm_cert_arn" {
  name = "/acm/av-cert-arn"
}
*/
data "aws_route53_zone" "r53_zone" {
  name = var.route53_domain
}

data "aws_eks_cluster" "cluster" {
  name = var.cluster
}

data "aws_ssm_parameter" "eks_lb_name" {
  name = "/eks/lb-name"
}

data "aws_ssm_parameter" "eks_lb_name_private" {
  name = "/eks/lb-name-private"
}

data "aws_lb" "eks_lb" {
  name = var.private ? data.aws_ssm_parameter.eks_lb_name_private.value : data.aws_ssm_parameter.eks_lb_name.value
}

data "aws_ssm_parameter" "role_boundary" {
  name = "/acs/iam/iamRolePermissionBoundary"
}

data "aws_caller_identity" "current" {}
/*
data "aws_eks_cluster" "selected" {
  name = data.aws_ssm_parameter.eks_cluster_name.value
}
*/

// ----------------------------------------------------
// IAM Role
// ----------------------------------------------------
data "aws_iam_policy_document" "eks_oidc_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_eks_cluster.cluster.identity.0.oidc.0.issuer, "https://", "")}:sub"
      values = [
        "system:serviceaccount:default:${var.name}",
      ]
    }

    principals {
      identifiers = [
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(data.aws_eks_cluster.cluster.identity.0.oidc.0.issuer, "https://", "")}"
      ]
      type = "Federated"
    }
  }
}

resource "aws_iam_role" "this" {
  name = "eks-${var.cluster}-${var.name}"

  assume_role_policy   = data.aws_iam_policy_document.eks_oidc_assume_role.json
  permissions_boundary = data.aws_ssm_parameter.role_boundary.value

  tags = {
    env  = var.environment
    repo = var.repo_url
  }

}

resource "aws_iam_policy" "this" {
  name   = "eks-${var.cluster}-${var.name}"
  policy = var.iam_policy_doc
}

resource "aws_iam_policy_attachment" "this" {
  name       = "eks-${var.cluster}-${var.name}"
  policy_arn = aws_iam_policy.this.arn
  roles      = [aws_iam_role.this.name]
}

// ----------------------------------------------------
// K8s Deployment, Service, Ingress
// ----------------------------------------------------
resource "kubernetes_service_account" "this" {
  metadata {
    name = var.name

    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.this.arn
    }

    labels = {
      "app.kubernetes.io/name"       = var.name
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "kubernetes_secret_v1" "this" {
  metadata {
    name        = "${var.name}-service-account-token"
    namespace   = kubernetes_service_account.this.metadata.0.namespace
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account.this.metadata.0.name
    }
  }

  type = "kubernetes.io/service-account-token"
}

resource "kubernetes_deployment" "this" {
  metadata {
    name = var.name

    labels = {
      "app.kubernetes.io/name"       = var.name
      "app.kubernetes.io/version"    = var.image_version
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = {
        "app.kubernetes.io/name" = var.name
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"    = var.name
          "app.kubernetes.io/version" = var.image_version
        }
      }

      spec {
        service_account_name = kubernetes_service_account.this.metadata.0.name

        dynamic "image_pull_secrets" {
          for_each = length(var.image_pull_secret) > 0 ? [var.image_pull_secret] : []

          content {
            name = image_pull_secrets.value
          }
        }

        container {
          name              = "server"
          image             = "${var.image}:${var.image_version}"
          image_pull_policy = "Always"

          args = var.container_args

          port {
            container_port = var.container_port
          }

          resources {
            limits = (var.resource_limits.cpu != null || var.resource_limits.memory != null) ? var.resource_limits : null
          }


          // environment vars
          dynamic "env" {
            for_each = var.container_env

            content {
              name  = env.key
              value = env.value
            }
          }

          // Volume mounts
          volume_mount {
            mount_path = "/var/run/secrets/kubernetes.io/serviceaccount"
            name       = kubernetes_secret_v1.this.metadata.0.name
            read_only  = true
          }

          // container is killed it if fails this check
          dynamic "liveness_probe" {
            for_each = var.health_check ? [1] : []

            content {
              http_get {
                port = var.container_port
                path = "/healthz"
              }

              initial_delay_seconds = 60
              period_seconds        = 60
              timeout_seconds       = 3
            }
          }

          // container is isolated from new traffic if fails this check
          dynamic "readiness_probe" {
            for_each = var.health_check ? [1] : []

            content {
              http_get {
                port = var.container_port
                path = "/healthz"
              }

              initial_delay_seconds = 30
              period_seconds        = 30
              timeout_seconds       = 3
            }
          }
        }

        volume {
          name = kubernetes_secret_v1.this.metadata.0.name

          secret {
            secret_name = kubernetes_secret_v1.this.metadata.0.name
          }
        }
      }
    }
  }

  timeouts {
    create = "5m"
    update = "5m"
    delete = "10m"
  }
}

// let everyone get to this service at one IP
resource "kubernetes_service" "this" {
  metadata {
    name = var.name

    labels = {
      "app.kubernetes.io/name"       = var.name
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    type = "ClusterIP"
    port {
      port        = 80
      target_port = var.container_port
    }

    selector = {
      "app.kubernetes.io/name" = var.name
    }
  }
}

// create the route53 entry
resource "aws_route53_record" "this" {
  count = length(var.public_urls)

  zone_id = data.aws_route53_zone.r53_zone.id
  name    = var.public_urls[count.index]
  type    = "A"

  alias {
    name                   = data.aws_lb.eks_lb.dns_name
    zone_id                = data.aws_lb.eks_lb.zone_id
    evaluate_target_health = false
  }
}

resource "kubernetes_ingress_v1" "this" {
  // only create the ingress if there is at least one public url
  count = length(var.public_urls) > 0 ? 1 : 0

  metadata {
    name = var.name

    labels = {
      "app.kubernetes.io/name"       = var.name
      "app.kubernetes.io/managed-by" = "terraform"
    }

    annotations = merge(var.ingress_annotations, {
      "kubernetes.io/ingress.class"  = "ingress-nginx"
    })
  }

  spec {
    dynamic "rule" {
      for_each = var.public_urls

      content {
        host = rule.value

        http {
          path {
            backend {
              service {
                name = kubernetes_service.this.metadata.0.name
                port {
                  number = 80
                }
              }
            }
          }
        }
      }
    }
  }
}
