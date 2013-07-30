module Spree
  class PaypalController < StoreController
    def express
      items = current_order.line_items.map do |item|
        {
          :Name => item.product.name,
          :Quantity => item.quantity,
          :Amount => {
            :currencyID => current_order.currency,
            :value => item.price
          },
          :ItemCategory => "Physical"
        }
      end

      tax_adjustments = current_order.adjustments.tax
      shipping_adjustments = current_order.adjustments.shipping

      current_order.adjustments.eligible.each do |adjustment|
        next if (tax_adjustments + shipping_adjustments).include?(adjustment)
        items << {
          :Name => adjustment.label,
          :Quantity => 1,
          :Amount => {
            :currencyID => current_order.currency,
            :value => adjustment.amount
          }
        }
      end
      # Because PayPal doesn't accept $0 items at all.
      # See #10
      items.map! do |item|
        item[:Amount][:value] = 0.01 if item[:Amount][:value] == 0
        item
      end

      total = current_order.adjustments.sum(:amount) + items.sum { |i| i[:Amount][:value] }
      binding.pry

      pp_request = provider.build_set_express_checkout({
        :SetExpressCheckoutRequestDetails => {
          :ReturnURL => confirm_paypal_url(:payment_method_id => params[:payment_method_id]),
          :CancelURL =>  cancel_paypal_url,
          :PaymentDetails => [{
            :OrderTotal => {
              :currencyID => current_order.currency,
              :value => current_order.total },
            :ItemTotal => {
              :currencyID => current_order.currency,
              :value => items.sum { |i| i[:Quantity] * i[:Amount][:value] } },
            :ShippingTotal => {
              :currencyID => current_order.currency,
              :value => current_order.ship_total },
            :TaxTotal => {
              :currencyID => current_order.currency,
              :value => current_order.tax_total },
            :ShipToAddress => address_options,
            :PaymentDetailsItem => items,
            :ShippingMethod => "Shipping Method Name Goes Here",
            :PaymentAction => "Sale",
      }]}})
      begin
        pp_response = provider.set_express_checkout(pp_request)
        if pp_response.success?
          redirect_to provider.express_checkout_url(pp_response)
        else
          flash[:error] = "PayPal failed. #{pp_response.errors.map(&:long_message).join(" ")}"
          redirect_to checkout_state_path(:payment)
        end
      rescue SocketError
        flash[:error] = "Could not connect to PayPal."
        redirect_to checkout_state_path(:payment)
      end
    end

    def confirm
      order = current_order
      order.payments.create!({
        :source => Spree::PaypalExpressCheckout.create({
            :token => params[:token],
            :payer_id => params[:PayerID]
        }, :without_protection => true),
        :amount => order.total,
        :payment_method => payment_method
      }, :without_protection => true)
      order.next
      if order.complete?
        flash.notice = Spree.t(:order_processed_successfully)
        redirect_to order_path(order, :token => order.token)
      else
        redirect_to checkout_state_path(order.state)
      end
    end

    def cancel
      flash[:notice] = "Don't want to use PayPal? No problems."
      redirect_to checkout_state_path(current_order.state)
    end

    private

    def payment_method
      Spree::PaymentMethod.find(params[:payment_method_id])
    end

    def provider
      payment_method.provider
    end

    def address_options
      {
        :Name => current_order.bill_address.try(:full_name),
        :Street1 => current_order.bill_address.address1,
        :Street2 => current_order.bill_address.address2,
        :CityName => current_order.bill_address.city,
        # :phone => current_order.bill_address.phone,
        :StateOrProvince => current_order.bill_address.state_text,
        :Country => current_order.bill_address.country.iso,
        :PostalCode => current_order.bill_address.zipcode
      }
    end
  end
end
