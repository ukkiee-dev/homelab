# 리뷰 M11: design §D14 "R2 egress + kube-dns + 같은 ns 앱 ingress + monitoring egress" 이행.
# 주의: K3s --disable-network-policy 상태 (memory `project_k3s_network_policy_disabled`) — 실제 차단 효과 0.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: __APP__-pg-ingress-egress
  namespace: __APP__
spec:
  podSelector:
    matchLabels:
      cnpg.io/cluster: __APP__-pg
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - podSelector: {}
      ports:
        - protocol: TCP
          port: 5432
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - protocol: TCP
          port: 9187
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: cnpg-system
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8
              - 172.16.0.0/12
              - 192.168.0.0/16
      ports:
        - protocol: TCP
          port: 443
